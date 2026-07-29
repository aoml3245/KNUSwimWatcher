import Foundation
import WatcherCore

private var passed = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    passed += 1
}

let html = """
<table>
  <tr><th>시간</th><th>요일</th><th>단계</th><th>현황</th></tr>
  <tr>
    <td>06:10</td><td>월 ~ 금</td><td>초급</td>
    <td>24 / 25명 <input type="submit" value="신청"></td>
  </tr>
</table>
"""

let rows = SportsClient.parseRows(html)
check(rows.count == 2, "표 행 파싱")
check(
    rows[1].cells == ["06:10", "월 ~ 금", "초급", "24 / 25명"],
    "셀 텍스트 파싱"
)
check(
    SportsClient.availability(of: rows[1])
        == .available(seats: 1, reason: "24/25명"),
    "잔여 인원 판정"
)

let closed = CourseRow(
    id: "closed",
    cells: ["19:00", "교정", "잔여 2명", "마감"],
    actions: ["신청"],
    hrefs: []
)
check(
    SportsClient.availability(of: closed) == .unavailable(reason: "마감"),
    "마감 표시 우선 판정"
)

let selection = WatchSelection(
    name: "아침 초급",
    keywords: ["06:10", "월 ~ 금", "초급"]
)
check(SportsClient.matches(rows[1], selection: selection), "선택 키워드 일치")

let candidates = SportsClient.candidateRows(from: [
    CourseRow(
        id: "swim",
        cells: ["수영", "18:00", "화, 목", "교정"],
        actions: [],
        hrefs: []
    ),
    CourseRow(
        id: "golf",
        cells: ["골프", "18:00", "화, 목"],
        actions: [],
        hrefs: []
    )
])
check(candidates.map(\.id) == ["swim"], "수영반 후보 필터")

check(
    SportsClient.classifyCoursePage("<p>로그인 후 이용해 주세요.</p>")
        == "unauthenticated",
    "비로그인 페이지 판정"
)
check(
    SportsClient.classifyCoursePage("<table><tr><td>수영</td></tr></table>")
        == "authenticated",
    "로그인 페이지 판정"
)
check(
    SportsClient.classifyLoginResponse("<script>비밀번호가 일치하지 않습니다</script>")
        == "rejected",
    "로그인 거절 응답 판정"
)
check(
    SportsClient.classifyCoursePage("<script>alert('로그인후 이용해 주세요.')</script>")
        == "unauthenticated",
    "축약 비로그인 응답 판정"
)

let precheckHTML = """
<form method="post" action="class_info5.php">
  <input type="radio" name="q1" value="1">예
  <input type="radio" name="q1" value="2">아니오
  <input type="radio" name="q2" value="Y">예
  <input type="radio" name="q2" value="N">아니오
  <input type="checkbox" name="agree" value="Y">
  <input type="checkbox" name="agree2" value="1">
</form>
"""
check(
    SportsClient.precheckSubmissionFields(precheckHTML)
        == ["q1": "2", "q2": "N", "agree": "Y", "agree2": "1"],
    "사전확인 조건 매핑"
)
check(
    SportsClient.firstFormAction(in: precheckHTML) == "class_info5.php",
    "사전확인 제출 경로"
)
check(SportsClient.firstFormMethod(in: precheckHTML) == "POST", "POST 폼 판정")

let legacyPrecheckHTML = """
<form method=post action='class_info5.php'>
  <input type=radio name='q1' value=1>예
  <input type=radio name='q1' value=2>아니오
  <input type=radio name='q2' value=Y>예
  <input type=radio name='q2' value=N>아니오
  <input type=checkbox name='agree' value=Y>
  <input type=checkbox name='agree2'>
</form>
"""
check(
    SportsClient.precheckSubmissionFields(legacyPrecheckHTML)
        == ["q1": "2", "q2": "N", "agree": "Y", "agree2": "on"],
    "구식 HTML 사전확인 매핑"
)
check(SportsClient.firstFormMethod(in: "<form action='x'>") == "GET", "기본 GET 폼 판정")

let programHTML = """
<form>
  <select name="PG_LECT_NM">
    <option value="">선택</option>
    <option value="SWIM">수영</option>
    <option value="GOLF">골프</option>
  </select>
  <select name="LECT_MONTH">
    <option value="202608">8월</option>
    <option value="202607" selected>7월</option>
  </select>
  <select name="LCTN_DVCD">
    <option value="">전체</option>
    <option value="MAIN" selected>본관</option>
  </select>
  <input type="hidden" name="mode" value="list">
</form>
"""
check(
    SportsClient.swimProgramSelectionFields(programHTML)
        == [
            "PG_LECT_NM": "SWIM",
            "LECT_MONTH": "202607",
            "LCTN_DVCD": "MAIN",
            "mode": "list"
        ],
    "수영 프로그램 선택 폼 매핑"
)

check(
    SportsClient.swimNavigationPath(
        from: [
            CourseRow(
                id: "nav",
                cells: ["수영"],
                actions: [],
                hrefs: ["/doc/class1.html"]
            )
        ]
    ) == "/doc/class1.html",
    "수영 상단 메뉴 경로"
)
check(
    SportsClient.swimNavigationPath(
        in: #"<nav><a href="/doc/class1.html"><span>수영</span></a></nav>"#
    ) == "/doc/class1.html",
    "DOM 수영 상단 메뉴 경로"
)

check(
    SportsClient.courseIdentityCells(
        lectureName: "강사:경북대, 수영 교정2반/ 강습 주2회 화,목 [18:00-18:50] (토) 자유수영 [06:00~18:00]",
        detailName: "교정2반 강습 주2회"
    ) == ["18:00-18:50", "교정2반", "주2회 · 화,목"],
    "실제 신청 강좌 시간·반·요일 분리"
)

let exactCourse = CourseRow(
    id: "lecture:10001234",
    cells: ["18:00-18:50", "교정2반", "주2회 · 화,목", "현재 23명 / 정원 25명", "잔여 2명"],
    actions: ["신청 가능"],
    hrefs: []
)
check(
    exactCourse.displayTitle == "18:00-18:50 · 교정2반 · 주2회 · 화,목",
    "신청 강좌 간결 제목"
)
check(
    exactCourse.capacityText == "현재 23명 / 정원 25명 · 잔여 2명",
    "신청 강좌 인원 표시"
)
let weekdayMorningCourse = CourseRow(
    id: "lecture:morning",
    cells: ["08:10-09:00", "초급반", "주5회 · 월,화,수,목,금", "잔여 1명"],
    actions: ["신청 가능"],
    hrefs: []
)
check(SportsClient.isWeekdayCourse(weekdayMorningCourse), "월~금 강좌 필터")
check(SportsClient.isMorningCourse(weekdayMorningCourse), "오전 강좌 필터")
let weekendAfternoonCourse = CourseRow(
    id: "lecture:weekend",
    cells: ["14:00-14:50", "교정반", "주3회 · 화,목,토", "잔여 1명"],
    actions: ["신청 가능"],
    hrefs: []
)
check(!SportsClient.isWeekdayCourse(weekendAfternoonCourse), "주말 포함 강좌 제외")
check(!SportsClient.isMorningCourse(weekendAfternoonCourse), "오후 강좌 제외")
check(
    CourseAvailability.available(seats: 1, reason: "잔여 1명")
        .isNewVacancy(comparedTo: nil),
    "첫 확인 빈자리 알림"
)
check(
    CourseAvailability.available(seats: 1, reason: "잔여 1명")
        .isNewVacancy(comparedTo: false),
    "없음에서 있음 전환 알림"
)
check(
    !CourseAvailability.available(seats: 1, reason: "잔여 1명")
        .isNewVacancy(comparedTo: true),
    "같은 빈자리 상태 중복 알림 방지"
)
check(
    !CourseAvailability.unavailable(reason: "마감")
        .isNewVacancy(comparedTo: false),
    "마감 상태 알림 제외"
)
check(
    SportsClient.matches(
        exactCourse,
        selection: WatchSelection(
            name: "저녁 교정2",
            keywords: [],
            courseID: "10001234"
        )
    ),
    "서버 강좌번호로 정확히 일치"
)

var seoulCalendar = Calendar(identifier: .gregorian)
seoulCalendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
let fixedDate = seoulCalendar.date(
    from: DateComponents(year: 2026, month: 7, day: 29)
)!
check(
    SportsClient.lecturePeriod(
        nominalMonths: 1,
        immediate: false,
        now: fixedDate,
        calendar: seoulCalendar
    ) == "2026년08월01일 부터 2026년08월31일 까지",
    "다음 달 수강기간 계산"
)

let confirmationHTML = """
<form name="mainform">
  <input type="hidden" name="lect_sqno" value="10002150" />
  <input type='hidden' name='PG_LECT_NM' value='수영 교정&amp;연수반' />
  <input name="visible" value="skip" />
</form>
"""
check(
    SportsClient.hiddenInputFields(in: confirmationHTML) == [
        "lect_sqno": "10002150",
        "PG_LECT_NM": "수영 교정&연수반"
    ],
    "최종 신청 숨은 필드 추출"
)
check(
    SportsClient.classifyRegistrationResult("<p>강좌신청이 완료되었습니다.</p>")
        == "success",
    "신청 성공 응답 판정"
)
check(
    SportsClient.classifyRegistrationResult("<script>alert('정원이 마감되었습니다')</script>")
        == "rejected",
    "신청 마감 응답 판정"
)
check(
    SportsClient.registrationBillIDs(
        in: """
        <a href="/doc/class_detail.php?BILL_SQNO=1111111111111111111">입금대기</a>
        <a href='class_detail.php?BILL_SQNO=2222222222222222222'>입금완료</a>
        """
    ) == ["1111111111111111111", "2222222222222222222"],
    "마이페이지 신청 번호 추출"
)

let legacySettingsJSON = """
{"account":"legacy","selectedClasses":[],"monitoringEnabled":true}
""".data(using: .utf8)!
let migratedSettings = try JSONDecoder().decode(
    WatcherSettings.self,
    from: legacySettingsJSON
)
check(!migratedSettings.autoRegistrationEnabled, "기존 설정 자동 신청 기본 꺼짐 마이그레이션")
check(
    migratedSettings.autoRegistrationAttemptedCourseID == nil,
    "기존 설정 신청 잠금 없음 마이그레이션"
)

let cachedRowsData = try JSONEncoder().encode(rows)
let restoredRows = try JSONDecoder().decode([CourseRow].self, from: cachedRowsData)
check(restoredRows == rows, "수영반 목록 캐시 직렬화")

print("KNUSwimWatcher self-test: \(passed) checks passed")
