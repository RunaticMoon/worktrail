# 인수 테스트 대응표 — 자동 테스트 대조

원본: `docs/mac_worklog_ai_handoff/04_IMPLEMENTATION_PLAN_AND_TESTS.md` (§3 흐름 A~E, §4~§8 인수 테스트 표)
대조 대상 저장소: 이 worktree (브랜치 `wlog-45a3/ae-acceptance-map`)
작성 기준 커밋: `d60125d` (`wlog-45a3/mvp`)

## 실행 환경과 명령

- 환경: Linux, Swift 6.3 툴체인 / aarch64-unknown-linux-gnu. **Linux(aarch64)에서 WorkLogCore와 그 테스트만 실행했다. macOS 앱 타깃(`Sources/WorkLogApp`)은 컴파일·실행하지 않았다.**
- `Sources/WorkLogApp/main.swift`는 현재 진입점 스텁(`// TODO: macOS SwiftUI 앱 진입점`)이며, 실제 SwiftUI/AppKit UI·전역 단축키 등록 코드는 아직 없다. 따라서 UI·전역 단축키·창 전환·실제 Keychain/Touch ID/NSPasteboard 어댑터가 필요한 항목은 이 환경에서 검증할 수 없다.
- 실행 명령과 실제 결과:

```text
$ swift test 2>&1 | tail -5
	 Executed 371 tests, with 0 failures (0 unexpected) in 43.944 (43.944) seconds
◇ Test run started.
↳ Testing Library Version: 6.3.3 (48d727cc1cf4eda)
↳ Target Platform: aarch64-unknown-linux-gnu
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

- 즉 XCTest 371개 전부 통과(실패 0), Swift Testing 스위트는 0개다. 아래 표의 "자동 테스트 통과"는 이 실행에서 해당 함수가 통과했고 기대 결과를 실제로 assert함을 확인한 것이다.

## 상태 정의

- `자동 테스트 통과` — 기대 결과를 assert하는 테스트가 있고 이번 실행에서 통과.
- `부분` — 일부 조건만 검증(빠진 점을 비고에 적음).
- `미검증(macOS)` — UI·전역 단축키·창 전환·실제 Keychain·Touch ID·NSPasteboard 등 Linux에서 실행 불가.
- `미검증(실계정)` — 실제 Codex Enterprise 계정·회사 정책 필요.
- `미구현` — 해당 기능 코드가 없음.

## ID 개수 대조

- 원본 04 문서의 인수 테스트 ID: **126개**
  - §4 입력·원문 CAP 10, §5 Task·프로젝트·계획 23 (TASK 9 + PROJ 8 + PLAN 6), §6 날짜·보고서·근거 32 (TIME 7 + REP 18 + QUIZ 4 + MEM 3), §7 Secret 30, §8 검색·AI·스케줄·백업 31 (SEARCH 8 + AI 9 + SCH 4 + BACK 8 + LINK 2).
- 이 문서의 표에 포함된 ID: **126개** (누락 0). 별도로 §3 흐름 A~E를 소절에서 단계별로 대조한다.

## 상태별 개수 요약

| 상태 | 개수 |
|---|---|
| 자동 테스트 통과 | 109 |
| 부분 | 12 |
| 미검증(macOS) | 4 |
| 미검증(실계정) | 0 (해당 ID 없음 — 실계정 잔여 항목은 §잔여 참고) |
| 미구현 | 1 |
| 합계 | 126 |

---

## 4. 입력·원문 (CAP)

| ID | 요구 | 시나리오(짧게) | 상태 | 근거 테스트(파일:함수) | 비고 |
|---|---|---|---|---|---|
| CAP-T01 | CAP-01 | 입력/검색 핫키 각각 실행 → 서로 다른 창/모드 | 미검증(macOS) | (없음) | 전역 단축키·창 분리 UI 코드 없음. 설정에 `captureHotkey`/`searchHotkey` 문자열과 검증만 존재(`Support/SettingsStore.swift`, `Domain/Models.swift`). |
| CAP-T02 | CAP-01 | 새 설치에서 다시 입력창 열기 → 기본 Memo | 부분 | SettingsStoreTests.swift:testEmptyObjectGivesAllDefaults | 기본값 `defaultCaptureKind = .memo`와 설정 디코딩은 검증. 입력창이 Memo로 열리는 UI 동작은 미검증. |
| CAP-T03 | CAP-01 | 기본 유형을 Task로 변경 후 재시작 → 유지 | 부분 | SettingsStoreTests.swift:testSaveThenLoadRoundTripAndPermissions | 설정 영속화는 검증. `defaultCaptureKind`를 Task로 바꾼 뒤 재시작·창 열림은 UI 미검증. |
| CAP-T04 | CAP-02 | Memo에서 Enter/⌘Enter/Esc 구분 | 미검증(macOS) | (없음) | 키 입력 처리 UI 코드 없음. |
| CAP-T05 | MEM-01 | 제목 없이 여러 줄 Memo 저장 | 자동 테스트 통과 | TaskServiceTests.swift:testCaptureMemoStoresMultilineBodyAndLinksWithoutFetch / WorkRepositoryTests.swift:testMemoRoundTripPreservesBodyPreviewAndLinks | 전체 원문·첫 줄 preview·업무일 보존 assert. |
| CAP-T06 | CAP-03 | 화요일에 월요일 업무 기록 | 자동 테스트 통과 | TaskServiceTests.swift:testCaptureMemoLateEntryBelongsToWorkDate / WorkRepositoryTests.swift:testLateEntryBelongsToWorkDateAndKeepsRecordedAt / DayBoxTests.swift:testLateActivityBelongsToItsWorkDateNotRecordDay | workDate 귀속과 recordedAt 보존, 타임라인 귀속 assert. |
| CAP-T07 | CAP-02 | AI·네트워크 끄고 저장 | 자동 테스트 통과 | AppEnvironmentTests.swift:testNilProviderDisablesAIButMemoWorks | AI provider 없이 Memo 저장·검색 성공. "지연" 시나리오는 미시뮬레이션. |
| CAP-T08 | CAP-01 | 다른 앱 사용 중 창 열기→저장→복귀 | 미검증(macOS) | (없음) | 창/포커스 전환 UI 코드 없음. |
| CAP-T09 | CAP-01 | 이미 사용 중인 단축키 설정 | 부분 | SettingsStoreTests.swift:testValidationRejectsInvalidValuesWithoutTouchingFile | 캡처=검색 단축키 동일 시 validation만 검증. OS가 점유한 단축키 등록 충돌·기존 동작 보존은 UI 미검증. |
| CAP-T10 | CAP-03 | 같은 날 늦은 상태 기록 순서 모순 | 자동 테스트 통과 | StateReplayTests.swift:testImpossibleTransitionIsReportedNotThrown / TaskServiceTests.swift:testPausedAfterCompletionIsRejectedWithoutSaving / TaskServiceTests.swift:testLateRecordedStartBeforeLaterCompletion | 불가능 전이는 violation으로 보고(날조 없음), 늦은 시작은 현재 완료를 뒤집지 않음. |

## 5. Task·프로젝트·계획 (TASK/PROJ/PLAN)

| ID | 요구 | 시나리오(짧게) | 상태 | 근거 테스트(파일:함수) | 비고 |
|---|---|---|---|---|---|
| TASK-T01 | TASK-01 | 시작일 없이 완료 Task 새 등록 | 자동 테스트 통과 | TaskServiceTests.swift:testCreateCompletedTaskHasNoStartedOnAndOneCompletionDate | `firstStartedOn == nil`, 완료일 1개. |
| TASK-T02 | TASK-05 | 기존 Task에 진행 기록 추가 | 자동 테스트 통과 | TaskServiceTests.swift:testAddActivityAppearsOnceOnItsDateAndDoesNotChangeStatus | 실제 날짜에 1회, 상태 불변. |
| TASK-T03 | TASK-02 | 진행→보류→진행 | 자동 테스트 통과 | TaskServiceTests.swift:testProgressPauseResumeKeepsHistory / StateReplayTests.swift:testPauseAndResumeHistory | 중단·재개 이력 보존. |
| TASK-T04 | TASK-02 | 일부 활동 후 취소 | 자동 테스트 통과 | TaskServiceTests.swift:testActivitySurvivesCancellationAndStatusIsNotCompleted | 활동 유지, 완료 실적 아님. |
| TASK-T05 | TASK-04 | 완료→재개→다시 완료 | 자동 테스트 통과 | TaskServiceTests.swift:testCompleteReopenCompleteHasTwoCompletionDatesAndOneTask / StateReplayTests.swift:testCompletionReopenCompletionHasTwoCompletionDates | 완료 사건 2개, Task 1개. |
| TASK-T06 | TASK-04 | 새로운 요구사항 추가 | 자동 테스트 통과 | TaskServiceTests.swift:testCreateFollowUpTaskKeepsOriginalCompletion | 후속 Task 생성, 기존 완료 유지. |
| TASK-T07 | TASK-03 | 모든 checklist 완료 | 자동 테스트 통과 | TaskServiceTests.swift:testAllChecklistDoneDoesNotCompleteTask / StateReplayTests.swift:testChecklistCompletionDoesNotChangeTaskAndCanReopen | Task 자동 완료 없음. |
| TASK-T08 | TASK-03 | 미완료 항목 있는 Task 전체 완료 클릭 | 자동 테스트 통과 | TaskServiceTests.swift:testCompleteTaskWithRemainingRequiresConfirmation | 남은 항목 안내 후 직접 확정, 위조 없음. |
| TASK-T09 | TASK-06 | checklist 하나 완료 | 자동 테스트 통과 | TaskServiceTests.swift:testChecklistCompletionDoesNotChangeProjectStatus | 프로젝트 자동 완료 없음. |
| PROJ-T01 | PROJ-01 | 공백 있는 @프로젝트와 #태그 입력 | 자동 테스트 통과 | WorkRepositoryTests.swift:testProjectNameWithSpacesAndConflictAndFindOrCreate / WorkRepositoryTests.swift:testTagFindOrCreate | 공백 포함 프로젝트명의 안정 ID·trim·conflict 검증. 태그는 findOrCreate만 검증(공백 태그 직접 케이스는 없음). |
| PROJ-T02 | PROJ-02 | A에 G·J·K 연결 | 자동 테스트 통과 | WorkRepositoryTests.swift:testTaskProjectLinksAndUnlink / SubmissionReportTests.swift:testRepT02CommonTaskNotRepeated / ReportFactsBuilderTests.swift:testMetrics | 연결 3개여도 Task 1건, 보고서 공통업무 1줄. |
| PROJ-T03 | PROJ-03 | G 완료/J 진행/K 예정 | 자동 테스트 통과 | TaskServiceTests.swift:testPerProjectStatusesAreIndependent / StateReplayTests.swift:testFixtureProjectStatesThroughSunday / ReportFactsBuilderTests.swift:testSubmissionFactsRangesAndStates | 세 상태와 전체 진행 공존. |
| PROJ-T04 | PROJ-03 | 모든 프로젝트 완료 | 자동 테스트 통과 | TaskServiceTests.swift:testAllProjectsCompletedDoesNotCompleteTask / StateReplayTests.swift:testAllProjectsCompletedDoesNotCompleteTask | 수동 완료 요구 유지. |
| PROJ-T05 | PROJ-03 | K만 취소 | 자동 테스트 통과 | TaskServiceTests.swift:testCancellingOneProjectLeavesOthersAndTaskUnchanged | 다른 프로젝트·전체 상태 불변. |
| PROJ-T06 | TASK-05 | 같은 기록에 G·J 연결 | 자동 테스트 통과 | WorkRepositoryTests.swift:testActivityWithMultipleProjects | 활동 1건, 두 프로젝트가 같은 근거 참조. |
| PROJ-T07 | TASK-05 | 프로젝트 미선택 공통 기록 추가 | 자동 테스트 통과 | TaskServiceTests.swift:testCommonActivityAddsNoProjectScopeEvent | project scope 사건 미생성. |
| PROJ-T08 | PROJ-03 | 확정 보고 후 프로젝트 이름/연결 변경 | 자동 테스트 통과 | ReportStoreTests.swift:testConfirmedPreservedAcrossAutomaticRegeneration / ReportServiceTests.swift:testConfirmedPreservedWhenSourceChanges | 확정본 본문 불변(DB 트리거)을 검증. 프로젝트 rename을 직접 입력으로 한 케이스는 없음(원본 변경 전반으로 검증). |
| PLAN-T01 | PLAN-01 | 지난주 미완료·이번 주 마감 후보 생성 | 자동 테스트 통과 | WeekPlanTests.swift:testCandidatesDoNotAppearUntilConfirmed / ReportFactsBuilderTests.swift:testConfirmedPlansExcludeCandidates | 후보는 보고 '예정'에 미포함. |
| PLAN-T02 | PLAN-01 | 후보 중 J와 공통 checklist만 확인 | 자동 테스트 통과 | WeekPlanTests.swift:testFixtureScenarioOnlyConfirmedSubsetAppears / ReportServiceTests.swift:testSubmissionDeterministicDraftFromFixture | 확정 범위만 이번 주 계획. |
| PLAN-T03 | PLAN-03 | 예정 Task를 계획에 포함 | 자동 테스트 통과 | WeekPlanTests.swift:testConfirmingPlannedTaskDoesNotCreateEventsOrStart | 상태 예정 유지, 시작일 미생성. |
| PLAN-T04 | PLAN-02 | Task 전체와 같은 세부 항목 함께 선택 | 자동 테스트 통과 | WeekPlanTests.swift:testWholeTaskAndDetailsMergeIntoOneFactPlanItem | 동일 계획 1개로 정규화. |
| PLAN-T05 | PLAN-01 | 보류/취소 Task 후보 처리 | 자동 테스트 통과 | WeekPlanTests.swift:testOnHoldAndCancelledTasksAreNotAutoCandidates | 자동 재개·자동 확정 없음. |
| PLAN-T06 | PLAN-02 | 한 checklist가 두 프로젝트에 연결 | 자동 테스트 통과 | WeekPlanTests.swift:testDuplicateChecklistScopeNormalizesToOne | checklist ID 기준 1개로 정규화. |

## 6. 날짜·보고서·근거 (TIME/REP/QUIZ/MEM)

| ID | 요구 | 시나리오(짧게) | 상태 | 근거 테스트(파일:함수) | 비고 |
|---|---|---|---|---|---|
| TIME-T01 | DAY-02 | 2026-10-05 월요일 보고 생성 | 자동 테스트 통과 | PeriodsTests.swift:testSubmissionWeekSplitsPreviousAndPlan | 지난주 09-28~10-04, 계획 10-05~10-11. |
| TIME-T02 | WEEK-01 | 일요일 진행, 월요일 09시 완료 | 자동 테스트 통과 | SubmissionReportTests.swift:testTimeT02MondayCompletionStaysInProgress / ReportFactsBuilderTests.swift:testSubmissionFactsRangesAndStates | 지난주 보고는 진행. |
| TIME-T03 | DAY-02 | 월요일 00:00 사건 | 자동 테스트 통과 | PeriodsTests.swift:testStateCutoffIsEndExclusiveLocalMidnight / ReportFactsBuilderTests.swift:testMondayEventNotIncludedInPreviousWeek | 전주 종료 범위(endExclusive)에 미포함. |
| TIME-T04 | DAY-01 | 같은 날 시작·완료 | 자동 테스트 통과 | DayBoxTests.swift:testSingleDayTimelineAndTaskRow / StateReplayTests.swift:testSameDayEffectiveOrderDecidesSequence | 두 사건 모두 존재, 완료 Task 1. |
| TIME-T05 | DAY-01 | 진행 중이나 해당 날짜 활동 없음 | 자동 테스트 통과 | DayBoxTests.swift:testInProgressTaskWithoutDayActivityAppearsOnlyInTaskColumn / ReportFactsBuilderTests.swift:testInProgressTaskWithoutActivityHasNoFakeActivity | 상태만 표시, 가짜 활동 없음. |
| TIME-T06 | DAY-03 | 화요일 완료 후 월요일 진행 기록 늦게 입력 | 자동 테스트 통과 | StateReplayTests.swift:testLateRecordedStartDoesNotUndoLaterCompletion / TaskServiceTests.swift:testLateRecordedStartBeforeLaterCompletion | 현재 완료 유지, 과거 상태 재생. |
| TIME-T07 | DAY-03 | 확정 후 소급 업무일로 기록 추가 | 자동 테스트 통과 | ReportServiceTests.swift:testConfirmedPreservedWhenSourceChanges / ReportStoreTests.swift:testConfirmedPreservedAcrossAutomaticRegeneration / ReportStoreTests.swift:testIsStaleDetectsSourceChange | 확정본 불변, stale 감지. |
| REP-T01 | WEEK-02 | 사용자 초기 양식으로 렌더링 | 자동 테스트 통과 | SubmissionReportTests.swift:testRenderMatchesInitialFormat | 제목 아래 완료/진행/예정 한 줄 형식. |
| REP-T02 | WEEK-03 | 다중 프로젝트 A 보고 | 자동 테스트 통과 | SubmissionReportTests.swift:testRepT02CommonTaskNotRepeated / ReportServiceTests.swift:testSubmissionDeterministicDraftFromFixture | 공통 업무 아래 1줄, 삼중 반복 없음. |
| REP-T03 | PERF-01 | 제출용과 상세 Weekly 동시 생성 | 자동 테스트 통과 | ReportServiceTests.swift:testSubmissionAndPerformanceAreSeparated / ReportStoreTests.swift:testEnsureReportIsIdempotentAndSeparatesFamilies / TemplateStoreTests.swift:testDefaultPromptContentsAndSeparation / ReportServiceTests.swift:testInstructionsHaveNoPlaceholdersAndFamilySpecificNotes | 다른 report ID/family·템플릿·본문. |
| REP-T04 | PERF-01 | 월을 가로지르는 주간 기록 | 자동 테스트 통과 | PeriodsTests.swift:testSplitWeekByMonth | 기간 분할 로직 검증(월 경계로 2구간). |
| REP-T05 | PERF-03 | 첫 평가 기간 생성 | 자동 테스트 통과 | EvaluationPeriodServiceTests.swift:testFirstPeriodRequiresStartAndBuildsRange / PeriodsTests.swift:testEvaluationPropose | 시작일 직접 지정, `[start, end+1)`. |
| REP-T06 | PERF-03 | 다음 평가 생성 | 자동 테스트 통과 | EvaluationPeriodServiceTests.swift:testNextPeriodDerivesStartFromConfirmedEnd / PeriodsTests.swift:testEvaluationNextStartRules | 확정 종료일 다음 날 시작. |
| REP-T07 | PERF-03 | 같은 평가 리포트의 새 버전 | 자동 테스트 통과 | EvaluationPeriodServiceTests.swift:testNewVersionKeepsRangeAndNextStart / ReportServiceTests.swift:testEvaluationReportRangeAndConfirm | 기간 전진 없음. |
| REP-T08 | PERF-03 | 집계 종료일과 생성일이 다름 | 자동 테스트 통과 | EvaluationPeriodServiceTests.swift:testClockDoesNotExtendRange / ReportServiceTests.swift:testEvaluationReportRangeAndConfirm | 생성일까지 근거 확장 없음. |
| REP-T09 | PERF-02 | 숫자 없는 성과 기록 | 부분 | PerformanceReportTests.swift:testMissingEvidence / PerformanceReportTests.swift:testValidateUnverifiedNumber | 컴포저가 수치·기여율을 임의 생성하지 않는다는 직접 assert는 없음. 근거 없는 수치는 `unverified_number` 경고로만 검증. |
| REP-T10 | PERF-02 | G 근거만 있는데 J 효과 요약 요청 | 자동 테스트 통과 | PerformanceReportTests.swift:testValidateProjectEvidenceMismatch / PerformanceReportTests.swift:testMultiProjectEvidenceWithoutProjectIsNotSpreadToAllProjects | project_evidence_mismatch 경고, G 효과 복제 금지. |
| REP-T11 | PERF-04 | 확정본 뒤 자동 재생성 | 자동 테스트 통과 | ReportStoreTests.swift:testConfirmedPreservedAcrossAutomaticRegeneration / ReportServiceTests.swift:testConfirmedPreservedWhenSourceChanges | 확정본 덮어쓰기 없음. |
| REP-T12 | PERF-04 | 수동 편집 중인 초안에 원본 변경 | 자동 테스트 통과 | ReportStoreTests.swift:testEditPreservedAcrossAutomaticRegeneration | 편집 손실 없이 새 버전 생성. |
| REP-T13 | WEEK-04 | 한 주 안에 완료 후 재개 | 자동 테스트 통과 | SubmissionReportTests.swift:testRepT13ReopenedStaysInProgressWithMarker | 최종 진행 + "(재개)" 표시. |
| REP-T14 | PERF-02 | 보류·취소 직전 실제 수행 있음 | 자동 테스트 통과 | PerformanceReportTests.swift:testValidateStatusMisrepresented / SubmissionReportTests.swift:testOnHoldAndCancelledGoToReviewNotes | 취소를 완료로 포장 안 함(reviewNotes 분리). |
| REP-T15 | PERF-04 | AI가 존재하지 않는 source ID 반환 | 자동 테스트 통과 | SubmissionReportTests.swift:testValidateUnknownEvidence / PerformanceReportTests.swift:testValidateUnknownEvidence / ReportStoreTests.swift:testUnknownEvidenceSourceIsExcludedWithWarning | 검증 실패·경고, 근거 제외. |
| REP-T16 | PERF-01 | 하위 리포트에 기간 밖 근거 포함 | 자동 테스트 통과 | ReportFactsBuilderTests.swift:testMetrics / PerformanceReportTests.swift:testValidateEvidenceOutOfRangeAndSupplementApplies | 기간 밖 활동은 facts에서 제외, 초과 근거는 경고. |
| REP-T17 | PERF-04 | 프롬프트 템플릿 복제·수정 | 자동 테스트 통과 | TemplateStoreTests.swift:testCloneIsIndependentFromSource / ReportStoreTests.swift:testEditConfirmedCreatesNewEditedVersion | 복제 독립성, 확정본 templateVersionId 보존. |
| REP-T18 | PERF-05 | AI 실패 후 재시도 | 자동 테스트 통과 | ReportServiceTests.swift:testAIFailureStillStoresDeterministicDraft / AIJobRunnerTests.swift:testRetryReusesRowUntilSuccess / AIJobRunnerTests.swift:testResubmitSameRequestReusesSucceededRow | 원문 보존, 동일 결과 행 재사용(중복 확정 없음). |
| QUIZ-T01 | QUIZ-01 | 원인·효과 부족한 Task | 자동 테스트 통과 | EvidenceQuizTests.swift:testGeneratesValidQuestions / EvidenceQuizTests.swift:testLaterIsNotExcludedButExcludedSurvivesDigestChange | 질문 생성 + later/excluded 건너뛰기 옵션. 카드 렌더링 UI는 미검증. |
| QUIZ-T02 | QUIZ-02 | 질문 모두 건너뛰고 보고 복사 | 부분 | EvidenceQuizTests.swift:testLaterIsNotExcludedButExcludedSurvivesDigestChange / ReportStoreTests.swift:testSecondConfirmKeepsPreviousConfirmed | 건너뛰기 저장·확정은 검증. 보고 클립보드 복사는 UI/NSPasteboard 미검증. |
| QUIZ-T03 | QUIZ-02 | 월요일에 지난주 성과 답변 | 자동 테스트 통과 | EvidenceQuizTests.swift:testRecordAnsweredUsesAppliesPeriod / ReportFactsBuilderTests.swift:testSupplementIsSourceNotActivity | applies=지난주, recordedAt=월요일, 활동 집계 아님. |
| QUIZ-T04 | QUIZ-02 | 같은 근거로 다시 질문 생성 | 자동 테스트 통과 | EvidenceQuizTests.swift:testAnsweredTopicExcludedOnRegenerate / EvidenceQuizTests.swift:testLaterIsNotExcludedButExcludedSurvivesDigestChange | answered/excluded 동일 질문 반복 방지. |
| MEM-T01 | MEM-02 | Memo→Task 연결 제안 생성 | 자동 테스트 통과 | MemoLinkSuggestionTests.swift:testSuggestStoresSingleProposedLink | 승인 전 `.proposed` 1건 저장. |
| MEM-T02 | MEM-02 | 연결 승인 | 자동 테스트 통과 | MemoLinkSuggestionTests.swift:testDecideDoesNotChangeTaskOrMemo / MemoLinkSuggestionTests.swift:testAcceptedLinkIsNotSuggestedAgain | 원문·Task 상태 불변, 자동 생성·완료 없음. |
| MEM-T03 | MEM-02 | URL 있는 Memo 연결 승인 | 부분 | MemoLinkSuggestionTests.swift:testDecideDoesNotChangeTaskOrMemo / TaskServiceTests.swift:testCaptureMemoStoresMultilineBodyAndLinksWithoutFetch | Task 자동 생성 없음은 간접 확인. URL 보유 Memo 승인 시 URL 수집 작업 미생성 시나리오는 직접 테스트 없음. |

## 7. Secret (SEC)

| ID | 요구 | 시나리오(짧게) | 상태 | 근거 테스트(파일:함수) | 비고 |
|---|---|---|---|---|---|
| SEC-T01 | SEC-01 | 네트워크/AI 끈 상태에서 생성·편집·검색·복사 | 자동 테스트 통과 | SecretVaultTests.swift:testPartialUpdateFixtureScenario / testSaveIncrementsRevision / testSearchTitlesEscapesLikeWildcards / VaultSessionTests.swift:testCopyValueWritesClipboardAndRefreshesActivity | Secret 경로에 AI·네트워크 의존성 없음. "AI 호출 수 0"을 직접 계수하는 assert는 없음(구조상 불가). |
| SEC-T02 | SEC-02 | value `00123`, `true`, `{x:1}` | 자동 테스트 통과 | SecretNormalizerTests.swift:testValuesAreKeptAsStrings / SecretVaultTests.swift:testDefaultTitleAndStringValues | 문자열 그대로. |
| SEC-T03 | SEC-03 | key `  API_KEY  `, value `  abc 123  ` | 자동 테스트 통과 | SecretNormalizerTests.swift:testSecretTrimCasesFromFixture / testTrimOnlyStripsLeadingAndTrailing | 앞뒤 trim. |
| SEC-T04 | SEC-03 | 앞뒤 탭·개행 + 내부 줄바꿈 | 자동 테스트 통과 | SecretNormalizerTests.swift:testTrimOnlyStripsLeadingAndTrailing / testSecretTrimCasesFromFixture | 앞뒤만 trim, 내부 보존. |
| SEC-T05 | SEC-03 | 대소문자·비ASCII·내부 연속 공백 | 자동 테스트 통과 | SecretNormalizerTests.swift:testTrimOnlyStripsLeadingAndTrailing / testSecretTrimCasesFromFixture | 앞뒤 외 변형 없음. |
| SEC-T06 | SEC-03 | 빈 key 새 값 2개, 기존 key1 | 자동 테스트 통과 | SecretNormalizerTests.swift:testAutoKeyAvoidsExistingKey1 / testTwoBlankKeysGetSequentialAutoKeys | key2/key3, 기존 보존. |
| SEC-T07 | SEC-03 | trim 후 같은 key 두 행 | 자동 테스트 통과 | SecretNormalizerTests.swift:testDuplicateKeyKeepsBothValues / SecretVaultTests.swift:testDuplicateKeyRejectedAndNothingSaved / testDuplicateKeyOnSaveRejectedAndRevisionUnchanged | 정규화는 두 값 유지+이슈, vault 저장은 거부(값 은닉 없음). |
| SEC-T08 | SEC-03 | 완전히 빈 새 행 | 자동 테스트 통과 | SecretNormalizerTests.swift:testBlankNewRowsAreIgnored | changed=false. |
| SEC-T09 | SEC-03 | 기존 value를 빈 문자열로 수정 | 자동 테스트 통과 | SecretNormalizerTests.swift:testUpdatingValueToEmptyIsKept | 명시적 빈 값 revision, 행 삭제와 구분. |
| SEC-T10 | SEC-04 | `A=B=C`, `A : B:C` 붙여넣기 | 자동 테스트 통과 | SecretNormalizerTests.swift:testPasteKeepsTrailingSeparatorsInValue / testPasteExamplesFromFixture | 값 `B=C`, `B:C` 유지. |
| SEC-T11 | SEC-04 | key 없는 값/URL/모호한 구분자 | 자동 테스트 통과 | SecretNormalizerTests.swift:testPasteUrlIsAmbiguousAndLossless / testPasteAmbiguousEmptyKeyKeepsWholeLine / testPasteNoSeparatorIsNotAmbiguous / testPasteOverlongKeyIsAmbiguous | ambiguous 플래그로 값 손실 없음. |
| SEC-T12 | SEC-04 | API_KEY 하나만 수정 | 자동 테스트 통과 | SecretNormalizerTests.swift:testSecretPartialUpdateFromFixture / SecretVaultTests.swift:testPartialUpdateFixtureScenario | HOST 등 보존. |
| SEC-T13 | SEC-04 | 여러 번 타이핑 후 1회 저장 | 자동 테스트 통과 | SecretVaultTests.swift:testSaveIncrementsRevision | 저장 단위 revision 1개. |
| SEC-T14 | SEC-04 | trim 후 변경 없는 저장 | 자동 테스트 통과 | SecretNormalizerTests.swift:testWhitespaceOnlyChangeIsNotChanged / SecretVaultTests.swift:testWhitespaceOnlySaveIsUnchanged | 불필요 revision 없음. |
| SEC-T15 | SEC-02 | 항목 key 이름 변경 | 자동 테스트 통과 | SecretNormalizerTests.swift:testRenamingKeyKeepsRowId / SecretVaultTests.swift:testKeyRenameKeepsRowIdAndHistory | 같은 row ID, 이전 값 이력. |
| SEC-T16 | SEC-05 | 잠금 상태에서 제목 검색 | 자동 테스트 통과 | VaultSessionTests.swift:testInitiallyLockedAndTitleSearchWorksWhileLocked | 제목 검색 가능, value 접근은 인증 필요. |
| SEC-T17 | SEC-05 | 검색 결과 key 선택 / 편집 셀 선택 | 미검증(macOS) | (Core: VaultSession.searchTitles/copyValue/currentRows) | "key 선택→복사 / 셀 선택→편집" UI 분기 코드 없음. |
| SEC-T18 | SEC-05 | 허용 시간 내 연속 복사 | 자동 테스트 통과 | VaultSessionTests.swift:testUnlockSucceedsThenNoReauthWithinWindow | 재인증 없음. |
| SEC-T19 | SEC-05 | 화면 잠금 또는 앱 종료 | 자동 테스트 통과 | VaultSessionTests.swift:testExplicitLockReasonsAndDuplicateLockCallbackOnce / AppEnvironmentTests.swift:testLockSecretsLocksVaultSession | `.screenLocked`/`.appQuit` 잠금 사유·중복 콜백 1회. 실제 macOS 이벤트 연결은 미검증. |
| SEC-T20 | SEC-05 | 복사 후 제한 시간 동안 clipboard 변경 없음 | 자동 테스트 통과 | VaultSessionTests.swift:testClipboardClearedAfterDelayWhenUnchanged | ClipboardGuard 로직 검증. 실제 NSPasteboard 어댑터는 macOS 미검증. |
| SEC-T21 | SEC-05 | 제한 시간 전 외부 복사 | 자동 테스트 통과 | VaultSessionTests.swift:testClipboardNotClearedWhenExternalCopyChangedMarker / testClearNowIfUnchanged | change marker 비교로 미삭제. NSPasteboard 어댑터는 macOS 미검증. |
| SEC-T22 | SEC-06 | 전체 Secret 삭제→검색→복원 | 자동 테스트 통과 | SecretVaultTests.swift:testTrashAndRestore | 일반 검색 제외 후 동일 항목·revision 복원. |
| SEC-T23 | SEC-06 | 행 하나 삭제→이전 버전 복원 | 자동 테스트 통과 | SecretVaultTests.swift:testRowDeleteThenRestoreRevisionKeepsHistory | 전체 휴지통 이동 없이 행 이력 복구. |
| SEC-T24 | SEC-06 | 휴지통 영구 삭제 | 부분 | SecretVaultTests.swift:testPurgeRemovesMetadataAndRevisions / testPurgeNonTrashedFails | metadata·revision 제거와 비휴지통 거부는 검증. 제목 인덱스 제거·"과거 백업 별개" 안내 문구는 직접 검증 없음. |
| SEC-T25 | SEC-07 | 고유 가짜 value 저장 후 파일·로그 검사 | 자동 테스트 통과 | SecretVaultTests.swift:testCanaryValuesAreNotPlaintextInDatabaseFiles / ReportFactsBuilderTests.swift:testSecretCanaryNeverAppearsInFacts | vault DB 파일·AI facts 평문 부재. 로그 파일 스캔은 미검증. |
| SEC-T26 | SEC-07 | Secret value로 일반/AI 검색 | 부분 | ReportFactsBuilderTests.swift:testSecretCanaryNeverAppearsInFacts / GroundedAnswerTests.swift:testInstructionsAndPayloadExcludePlaceholderAndSecretWords / MemoLinkSuggestionTests.swift:testBuildPayloadIsDeterministicAndFreeOfSecretTerms | AI 입력 미포함은 검증. 일반 검색 색인에서 Secret 값 배제를 직접 assert하는 테스트 없음(구조상 vault 미색인). |
| SEC-T27 | SEC-07 | 암호문 한 바이트 변조 | 자동 테스트 통과 | SecretVaultTests.swift:testTamperedCiphertextFailsIntegrity / testSwappedPayloadFailsIntegrityByAAD | integrity 오류, 평문 미표시. |
| SEC-T28 | SEC-07 | Keychain 키 없음 | 자동 테스트 통과 | SecretVaultTests.swift:testMissingKeyKeepsVaultUnchanged / testMissingKeyCurrentRowsThrows / AppEnvironmentTests.swift:testOpenSucceedsWithoutKeyAndUnlockReportsMissing | 기존 데이터 보존, 새 키 overwrite 금지. 실제 Keychain 어댑터는 macOS 미검증. |
| SEC-T29 | SEC-07 | Secret 초안 작성→닫기/재시작 | 자동 테스트 통과 | SecretVaultTests.swift:testDraftRoundTripAndNoPlaintext / testClearDraft | 암호화 초안 왕복, 평문 파일 없음. |
| SEC-T30 | SEC-07 | 모든 일반 AI job 입력 수집 | 자동 테스트 통과 | ReportFactsBuilderTests.swift:testSecretCanaryNeverAppearsInFacts / AIJobRunnerTests.swift:testPayloadGuardBlocksBeforeCreatingRowOrCallingProvider / AppEnvironmentTests.swift:testAIPayloadGuardBlocksVaultPath | Secret 제목/그룹/key/value 미포함, vault 경로 차단. |

## 8. 검색·AI·스케줄·백업 (SEARCH/AI/SCH/BACK/LINK)

| ID | 요구 | 시나리오(짧게) | 상태 | 근거 테스트(파일:함수) | 비고 |
|---|---|---|---|---|---|
| SEARCH-T01 | SEARCH-01 | 신규 저장 직후 검색 | 자동 테스트 통과 | SearchIndexTests.swift:testSEARCH_T01_ImmediateIndexAndSoftDeleteExclusion | 별도 rebuild 없이 즉시, soft delete 제외. |
| SEARCH-T02 | SEARCH-01 | 한글/영문/기호/공백 검색 | 자동 테스트 통과 | SearchIndexTests.swift:testSEARCH_T02_KoreanEnglishSymbolsAndAndQuery | 대소문자 무시, 기호, 두 단어 AND. |
| SEARCH-T03 | SEARCH-01 | 1~2글자 한글 부분 검색 | 자동 테스트 통과 | SearchIndexTests.swift:testSEARCH_T03_ShortKoreanTermsUseLikePath | LIKE 경로. |
| SEARCH-T04 | SEARCH-01 | 날짜·프로젝트·태그 필터 | 자동 테스트 통과 | SearchIndexTests.swift:testSEARCH_T04_Filters / testLateEntryFilteredByWorkDate | 합성 필터·실제 업무일 일치. |
| SEARCH-T05 | SEARCH-02 | 검색어만 타이핑 | 부분 | GroundedAnswerTests.swift:testNoEvidenceSkipsAI / testCollectsEvidenceAndCallsAIOnce | 검색 경로는 AI를 호출하지 않도록 구현되어 있으나, "검색만으로 AI 호출 0"을 검색 경로에서 직접 assert하는 테스트 없음. |
| SEARCH-T06 | SEARCH-02 | AI 답변 명시적 실행 | 자동 테스트 통과 | GroundedAnswerTests.swift:testCollectsEvidenceAndCallsAIOnce | 일반 근거만 payload 전달, source ID/type 반환. 클릭 이동 UI는 미검증. |
| SEARCH-T07 | SEARCH-02 | 답을 뒷받침할 근거 없음 | 자동 테스트 통과 | GroundedAnswerTests.swift:testNoEvidenceSkipsAI / testUnknownEvidenceIdsRemovedWithWarning | AI 호출 0 + 모른다고 표시, 날조 없음. |
| SEARCH-T08 | SEARCH-02 | Secret 전용 검색 모드 | 부분 | VaultSessionTests.swift:testInitiallyLockedAndTitleSearchWorksWhileLocked / GroundedAnswerTests.swift:testInstructionsAndPayloadExcludePlaceholderAndSecretWords | Secret 제목 검색은 별도 vault 경로로 AI 미사용. "AI 실행 불가·query 미전송"을 명시한 전용 모드·테스트는 없음. |
| AI-T01 | AI-01 | Codex 설치/계정 없음 | 자동 테스트 통과 | CodexAppServerProviderTests.swift:testCheckCapabilitiesWhenExecutableMissing / AppEnvironmentTests.swift:testNilProviderDisablesAIButMemoWorks | 설치 미탐지 + 로컬 기능 사용. 준비 안내 문구·실제 codex 설치는 미검증. |
| AI-T02 | AI-01 | 회사 정책으로 모델/도구 제한 | 자동 테스트 통과 | AIJobRunnerTests.swift:testErrorClassificationMapsProviderErrors / CodexAppServerProviderTests.swift:testFailedTurnClassifiesErrors / testErrorClassifierKeywords | policyRestricted → blockedPolicy. 실계정 정책 환경은 미검증(모의 오류). |
| AI-T03 | AI-01 | 사용 한도/인증 만료 | 자동 테스트 통과 | AIJobRunnerTests.swift:testErrorClassificationMapsProviderErrors / ReportServiceTests.swift:testAIFailureStillStoresDeterministicDraft | 실패/인증만료 매핑, 다른 API·개인 계정 자동 전환 없음(결정적 초안 대체). 실사용 한도 환경은 미검증. |
| AI-T04 | AI-01 | 기존 스킬 조회/선택 | 자동 테스트 통과 | CodexAppServerProviderTests.swift:testListAvailableSkillsParsesAndDoesNotWrite | 발견 스킬만 사용, 쓰기 메서드 미호출. |
| AI-T05 | AI-01 | 스킬 파일 변경/삭제 | 부분 | AIJobRunnerTests.swift:testDigestAndKeyChangeWithInputs | SkillRef.contentHash가 idempotency key에 반영되는 것은 검증. 실제 파일 변경 감지·출처 버전 보존의 직접 테스트 없음. |
| AI-T06 | AI-01 | 프로토콜 불일치·끊긴 JSON·취소 | 자동 테스트 통과 | CodexAppServerProviderTests.swift:testTransportCloseFailsRunAndIgnoresMalformedLine / testCancelSendsInterruptAndRunIsCancelled / testErrorClassifierKeywords / JSONRPCConnectionTests.swift:testMalformedLineIsCountedAndConnectionContinues | 안전 오류·취소, DB 훼손 없음. |
| AI-T07 | AI-01 | 샌드박스에서 가짜 vault 경로 읽기 시도 | 자동 테스트 통과 | AppEnvironmentTests.swift:testAIPayloadGuardBlocksVaultPath / AIJobRunnerTests.swift:testPayloadGuardBlocksBeforeCreatingRowOrCallingProvider / testOutputContainingBlockedPathIsNotStored | vault 경로 차단. 실제 codex read-only 샌드박스는 실계정 미검증. |
| AI-T08 | AI-01 | 광범위한 권한을 요구하는 스킬 | 자동 테스트 통과 | CodexAppServerProviderTests.swift:testRunDeclinesCommandExecutionApproval / testRunAccumulatesDeltasAndStripsCodeFence | 승인 요청 decline, sandbox read-only·approvalPolicy never. |
| AI-T09 | AI-01 | 근거 문서 인젝션 문구 | 부분 | AIJobRunnerTests.swift:testPayloadGuardBlocksBeforeCreatingRowOrCallingProvider / testOutputContainingBlockedPathIsNotStored | vault 경로·민감 출력 차단 가드는 검증. "설정 무시" 프롬프트 인젝션을 자료로만 취급하는 직접 테스트 없음. |
| SCH-T01 | PERF-05 | 자정에 앱 실행 중 | 자동 테스트 통과 | SchedulerTests.swift:testDueDailyCloseAtNextMidnight | 전날 Daily job 1개. |
| SCH-T02 | PERF-05 | 자정에 절전, 다음 날 실행 | 자동 테스트 통과 | SchedulerTests.swift:testMissedDailyJobsInDateOrderAndLate | 누락 복구·late 판정. |
| SCH-T03 | PERF-05 | 동일 작업 알림 중복·재시작 | 자동 테스트 통과 | SchedulerTests.swift:testRunDueIsIdempotentPerJob / testRunDueFailureRetriesThenStops / testResetStaleRunningAndRerun | idempotency·재시도·중복 행 방지. |
| SCH-T04 | PERF-05 | 날짜 범위에 원문 없음 | 자동 테스트 통과 | PerformanceReportTests.swift:testEmptyFacts / AppEnvironmentTests.swift:testScheduledJobsGenerateSeparateSubmissionAndPerformanceReports | 빈 입력은 "기록 없음", 없는 성과 미생성. |
| BACK-T01 | BACKUP-01 | 첫 실행 | 자동 테스트 통과 | BackupServiceTests.swift:testBackupRootIsCreatedAutomatically / AppEnvironmentTests.swift:testOnLaunchSeedsTemplatesAndCreatesBackupOnce | 홈 하위 폴더 자동 생성(0700). |
| BACK-T02 | BACKUP-01 | 변경된 데이터 일일 백업 | 자동 테스트 통과 | BackupServiceTests.swift:testCreateBackupProducesVerifiedManifest / testDailyBackupOnlyWhenChanged | 완성 manifest(해시 검증)·변경 시에만 daily. |
| BACK-T03 | BACKUP-03 | 백업 도중 쓰기·강제 중단 | 자동 테스트 통과 | BackupServiceTests.swift:testFailedBackupKeepsExistingBackupAndCleansTemp | 이전 성공본 보존, 임시/불완전본 없음, 실패 상태 기록. |
| BACK-T04 | BACKUP-02 | 백업 내용 검사 | 자동 테스트 통과 | BackupServiceTests.swift:testBackupContainsCiphertextButNoKeyOrPlaintext | vault 암호문 포함, vault 키·Secret 평문 부재. Codex 토큰은 백업 대상 파일에 없음(별도 assert는 없음). |
| BACK-T05 | BACKUP-03 | 손상된 manifest/DB 복원 | 자동 테스트 통과 | BackupServiceTests.swift:testCorruptedBackupFailsVerificationAndLeavesTargetUntouched / testVerifyRejectsManifestKeyVersionMismatch | 검증 실패, 대상 데이터 불변. |
| BACK-T06 | BACKUP-03 | 같은 Mac과 키를 유지한 복원 | 자동 테스트 통과 | BackupServiceTests.swift:testRestoreRoundTripWithSharedKeyStore | 기록·Task·활동·확정본·Secret revision 복구, preRestore 보존. |
| BACK-T07 | BACKUP-03 | Secret 키 없는 복원 | 자동 테스트 통과 | BackupServiceTests.swift:testRestoreWithoutVaultKeyPreservesTargetVault / testRestoreRejectsWrongKeyBytesAndLeavesTargetUntouched | vaultKeyMissing·vaultKeyMismatch, 대상 보관함 불변. |
| BACK-T08 | BACKUP-01 | 새 백업 실패 + retention | 자동 테스트 통과 | BackupServiceTests.swift:testRetentionKeepsNewestAndRespectsFailureFlag | 실패 시 삭제 없음, 최신 1개 보존. |
| LINK-T01 | LINK-01 | PR/Jira URL 저장(첫 버전) | 자동 테스트 통과 | TaskServiceTests.swift:testCaptureMemoStoresMultilineBodyAndLinksWithoutFetch / WorkRepositoryTests.swift:testChecklistActivityChecklistAndLinks | URL 보관만, linkType githubPullRequest/jiraIssue, fetch 없음. |
| LINK-T02 | LINK-02 | 향후 Task 링크 수집 | 미구현 | (없음) | 후속 L1 범위. `LinkExtractor`는 모든 http/https URL을 추출(fetch 없음)하며 PR/Jira만 수집·Memo/Confluence/재귀 URL 제외 로직은 없음. |

---

## 3. 사용자 여정 A~E 대조

Core 자동 테스트로 덮이는 단계와 UI/수동 시연이 필요한 단계를 구분한다. "Core ✓"는 이번 `swift test`에서 연결 테스트가 통과한 것, "UI 필요"는 macOS 앱 타깃이 스텁이라 Linux에서 검증 불가인 것, "수동/실계정"은 실제 계정·기기·정책이 필요한 것이다.

### 흐름 A — 업무 중 기록
| 단계 | 내용 | 상태 | 근거/사유 |
|---|---|---|---|
| A1 | 다른 앱에서 입력 핫키 | UI 필요(미검증 macOS) | 전역 단축키 등록 코드 없음(CAP-T01). |
| A2 | Memo 본문 작성·저장 | Core ✓ | TaskServiceTests:testCaptureMemoStoresMultilineBodyAndLinksWithoutFetch (CAP-T05). |
| A3 | 새 진행 Task 생성 | Core ✓ | TaskServiceTests:testCreateTaskNoteBecomesActivity / testAddActivityAppearsOnceOnItsDateAndDoesNotChangeStatus (TASK-T02). |
| A4 | 기존 Task에 확인사항·링크 | Core ✓ | TaskServiceTests:testActivityBodyAndExplicitLinksAreStored. |
| A5 | 완료 업무를 새 완료 Task로 | Core ✓ | TaskServiceTests:testCreateCompletedTaskHasNoStartedOnAndOneCompletionDate / testCreateFollowUpTaskKeepsOriginalCompletion (TASK-T01/T06). |
| A6 | 오늘 화면 타임라인·Task·Memo | Core ✓ | DayBoxTests:testSingleDayTimelineAndTaskRow (TIME-T04). |
| A7 | 검색 핫키로 원문 찾기 | 부분 (검색 Core ✓ / 핫키 UI 필요) | SearchIndexTests:testSEARCH_T01 (SEARCH-T01); 핫키 트리거는 UI 필요. |

### 흐름 B — 여러 프로젝트의 공통 업무
| 단계 | 내용 | 상태 | 근거/사유 |
|---|---|---|---|
| B1 | @G @J @K + 프로젝트별 적용 관리 | Core ✓ | TaskServiceTests:testPerProjectStatusesAreIndependent / WorkRepositoryTests:testTaskProjectLinksAndUnlink (PROJ-T02/T03). |
| B2 | G 완료/J 진행/K 예정 | Core ✓ | TaskServiceTests:testPerProjectStatusesAreIndependent (PROJ-T03). |
| B3 | 전체 Task는 진행 유지 | Core ✓ | PROJ-T04 테스트(testAllProjectsCompletedDoesNotCompleteTask). |
| B4 | 후보에서 J 적용·공통 체크리스트만 확정 | Core ✓ | WeekPlanTests:testFixtureScenarioOnlyConfirmedSubsetAppears (PLAN-T02). |
| B5 | 보고서 공통 업무 1회, K 미포함 | Core ✓ | SubmissionReportTests:testRepT02CommonTaskNotRepeated / ReportServiceTests:testSubmissionDeterministicDraftFromFixture (REP-T02, PLAN-T01). |
| B6 | 모든 부분 완료돼도 전체 완료 직접 | Core ✓ | PROJ-T04 테스트. |

### 흐름 C — 월요일 보고와 성과 축적
| 단계 | 내용 | 상태 | 근거/사유 |
|---|---|---|---|
| C1 | 일요일 종료 상태로 지난주 초안 | Core ✓ | ReportFactsBuilderTests:testKnownAtExcludesLaterRecords / testSubmissionFactsRangesAndStates (TIME-T03, REP-T01). |
| C2 | 월요일 완료가 지난주 완료로 안 바뀜 | Core ✓ | SubmissionReportTests:testTimeT02MondayCompletionStaysInProgress (TIME-T02). |
| C3 | 이번 주 계획 후보에서 선택 | Core ✓ | WeekPlanTests:testCandidatesDoNotAppearUntilConfirmed (PLAN-T01). |
| C4 | 성과 질문 하나 답·나머지 건너뜀 | Core ✓ | EvidenceQuizTests:testRecordAnsweredUsesAppliesPeriod / testLaterIsNotExcludedButExcludedSurvivesDigestChange (QUIZ-T03/T04). |
| C5 | 짧은 제출용 텍스트 복사·확정 | 부분 (확정 Core ✓ / 복사 UI 필요) | ReportStoreTests:testSecondConfirmKeepsPreviousConfirmed; 클립보드 복사는 NSPasteboard/UI 미검증(QUIZ-T02). |
| C6 | 상세 Weekly에 추가 답변·원문 근거 | Core ✓ | ReportFactsBuilderTests:testSupplementIsSourceNotActivity / PerformanceReportTests:testEvidenceItemsKindsOrderAndText. |
| C7 | 다음 날 늦은 기록 추가해도 확정 문장 불변 | Core ✓ | ReportServiceTests:testConfirmedPreservedWhenSourceChanges / ReportStoreTests:testIsStaleDetectsSourceChange (REP-T11, TIME-T07). |

### 흐름 D — Secret
| 단계 | 내용 | 상태 | 근거/사유 |
|---|---|---|---|
| D1 | key/value를 앞뒤 공백과 함께 입력 | Core ✓ | SecretNormalizerTests:testSecretTrimCasesFromFixture (SEC-T03). |
| D2 | 저장 후 trim·내부 공백 보존 확인 | Core ✓ | testTrimOnlyStripsLeadingAndTrailing / testValuesAreKeptAsStrings (SEC-T04/T05). |
| D3 | 제목 검색 후 인증, key 선택으로 복사 | 부분 (검색·인증·복사 Core ✓ / 선택 UI 필요) | VaultSessionTests:testInitiallyLockedAndTitleSearchWorksWhileLocked / testCopyValueWritesClipboardAndRefreshesActivity (SEC-T16, SEC-T17 UI). |
| D4 | API_KEY 행 하나만 수정 | Core ✓ | SecretVaultTests:testPartialUpdateFixtureScenario (SEC-T12). |
| D5 | 이전 값을 이력에서 확인 | Core ✓ | SecretVaultTests:testKeyRenameKeepsRowIdAndHistory / testRowDeleteThenRestoreRevisionKeepsHistory (SEC-T15/T23). |
| D6 | 전체 Secret 휴지통·복원 | Core ✓ | SecretVaultTests:testTrashAndRestore (SEC-T22). |
| D7 | AI 비활성·오프라인에서도 작동 | Core ✓ | Secret 경로 AI 비의존(SEC-T01); AppEnvironmentTests:testNilProviderDisablesAIButMemoWorks. |

### 흐름 E — 백업과 복구
| 단계 | 내용 | 상태 | 근거/사유 |
|---|---|---|---|
| E1 | 홈 하위 폴더 자동 생성 | Core ✓ | BackupServiceTests:testBackupRootIsCreatedAutomatically (BACK-T01). |
| E2 | 일반 기록·Secret 변경 후 백업 | Core ✓ | testCreateBackupProducesVerifiedManifest / testBackupContainsCiphertextButNoKeyOrPlaintext (BACK-T02/T04). |
| E3 | 별도 경로 복원, revision·계획·확정본 비교 | Core ✓ | testRestoreRoundTripWithSharedKeyStore (BACK-T06). |
| E4 | 키 없는 환경 복원 실패 안내 | Core ✓ | testRestoreWithoutVaultKeyPreservesTargetVault (BACK-T07). |
| E5 | 실패 시 기존 보관함 미덮어쓰기 | Core ✓ | testRestoreRejectsWrongKeyBytesAndLeavesTargetUntouched / testCorruptedBackupFailsVerificationAndLeavesTargetUntouched (BACK-T05/T07). |

---

## 잔여(미검증·미구현) 요약

`부분` 12건 — 빠진 조건:
- CAP-T02, CAP-T03 — 입력창 열림/defaultCaptureKind 변경·재시작 UI 미검증.
- CAP-T09 — OS 점유 단축키 충돌·기존 동작 보존 UI 미검증.
- REP-T09 — 컴포저가 수치·기여율을 임의 생성하지 않음을 직접 assert하는 테스트 없음.
- QUIZ-T02 — 보고 클립보드 복사 UI/NSPasteboard 미검증.
- MEM-T03 — URL 보유 Memo 승인 시 URL 수집 작업 미생성 직접 시나리오 없음.
- SEC-T24 — 제목 인덱스 제거·"과거 백업 별개" 안내 문구 미검증.
- SEC-T26 — 일반 검색 색인에서 Secret 값 배제를 직접 assert하는 테스트 없음.
- SEARCH-T05 — 검색만으로 AI 미호출을 직접 assert하는 테스트 없음.
- SEARCH-T08 — Secret 전용 검색 모드의 "AI 실행 불가·query 미전송" 직접 검증 없음.
- AI-T05 — 실제 스킬 파일 변경 감지·출처 버전 보존 직접 테스트 없음.
- AI-T09 — 프롬프트 인젝션을 자료로만 취급하는 직접 테스트 없음.

`미검증(macOS)` 4건 — CAP-T01, CAP-T04, CAP-T08, SEC-T17. 모두 전역 단축키·입력/창 UI·복사/편집 UI 선택 동작이며, `Sources/WorkLogApp/main.swift`가 스텁이라 실행 코드가 없다.

`미구현` 1건 — LINK-T02(후속 L1 범위, PR/Jira 한정 링크 수집).

`미검증(실계정)`으로 분류할 독립 ID는 없다. 다만 다음 항목은 실제 Codex Enterprise 계정·회사 정책·macOS 기기에서의 별도 실환경 확인이 필요하다(각 ID는 모의 provider/FakeCodexServer로 결정적 동작만 검증):
- AI-T01~AI-T09 중 실제 codex 바이너리·인증·정책·read-only 샌드박스(특히 AI-T02, AI-T03, AI-T07).
- 실제 macOS Keychain/Touch ID/Secure Enclave 대체물(현재 `InMemoryVaultKeyStore`·`MockDeviceAuthenticator`): SEC-T17~T21, SEC-T28.
- 실제 NSPasteboard 어댑터: SEC-T20, SEC-T21, QUIZ-T02.
- 실제 백업 파일에서 Codex 토큰 부재 확인: BACK-T04.
