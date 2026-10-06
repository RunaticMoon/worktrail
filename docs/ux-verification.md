# UX 검증 결과 (UXFL-E55A, 2026-10-05 KST)

대상: 브랜치 `wlog-uxfl/uxfl-e55a-ux-flows`, 검증 대상 커밋 `02fdf34`. 이 문서와 함께 `Tests/WorkLogCoreTests/UXFlowVerificationTests.swift`(8개 테스트)를 추가했다.
기준: `request.md`의 "필수 검증", `docs/ux-flows.md`, `docs/ux-components.md`, `AGENTS.md`.

**범위 한계.** 이 검증은 Linux(aarch64) 서버에서 실행했다. `WorkLogApp`(SwiftUI/AppKit)은 `#if os(macOS)` 코드라 여기서 컴파일하거나 실행할 수 없다. 그래서 아래 "결과"는 **Core(`WorkLogCore`) 동작**만 뜻한다. 실제 Mac에서의 화면, IME, 포커스, 접근성, 렌더링은 **검증하지 않았다**(§4).

## 1. 실행한 검증

| # | 명령 | 환경 | 결과 |
|---|---|---|---|
| 1 | `swift build --build-tests` | Linux aarch64, Swift 6.3.3 | exit 0 (Build complete) |
| 2 | `swift test --filter UXFlowVerificationTests` | 같음 | exit 0 · 8개 실행, 실패 0 |
| 3 | `swift test` (전체) | 같음 | exit 0 · **765개 실행, 실패 0** (0 unexpected), 48.6초 |
| 4 | `swiftc -frontend -parse -target arm64-apple-macos14 Sources/WorkLogApp/*.swift` | 같음(macOS SDK 없음) | exit 0 · 구문 파싱만 확인했다. 타입 검사는 하지 않았다 |
| 5 | 정적 grep(§3 보안) | 같음 | 아래 §3 참고 |

- 기준선: 지휘자가 `5bab107`에서 실행한 `swift test`는 757개, 실패 0이었다. 이번 실행은 그 757개에 새 테스트 8개를 더한 765개이며, 실패나 회귀는 없었다.
- 위 명령은 모두 2026-10-05 12:35 KST 무렵 `02fdf34`에 새 테스트 파일을 더한 작업 트리에서 실행했다.

### macOS CI(지휘자 제공 — 검증자가 직접 확인하지 않음)

| 실행 ID | 커밋 | 결론 | 내용(지휘자 설명) |
|---|---|---|---|
| 37256853093 | `de7dde3` | success | 빠른 입력, 검색, Secret UI, Core 타입 검사·테스트, DMG |
| 37258026218 | `9579e0d` | success | 주간보고·설정 UI 병합 |
| 37258389054 | `fc419ab` | success | 전체 UI 통합 macOS 타입 검사, Core 테스트, DMG |
| 37259663935 | `02fdf34` | success (지휘자 제공: macOS 빌드·타입검사·Core 테스트·DMG 통과) | 검토 L·M 수정 반영 |

CI에서 하는 일은 macOS 빌드·타입 검사와 Core 테스트, DMG 생성이다. UI 자동 조작 테스트는 포함되지 않으므로, CI가 통과해도 §4의 항목은 검증된 것이 아니다.

## 2. 흐름별 결과

"결과"는 Core 테스트 결과다. 근거로 든 테스트는 모두 3번 전체 실행에서 통과했다. **굵은 이름**은 이번에 새로 추가한 `UXFlowVerificationTests` 테스트다.

| 흐름 | Core 근거(테스트) | 결과 | Mac에서만 확인할 수 있는 남은 항목 |
|---|---|---|---|
| ① 다른 앱에서 한국어 Memo를 손실 없이 저장 | **testKoreanMemoKeepsEveryScalarAndSecondSubmitDoesNotDuplicate**(NFC·NFD 자모, 이모지, 탭, CRLF, 앞뒤 공백을 유니코드 스칼라 단위로 그대로 저장. 두 번째 저장은 거부되어 메모 1개만 남음. 마지막 글자 유지, 검색됨) · PresentationTests.testMemoPreservesOriginalAndRefreshesDayAndSearch · CaptureSessionTests.testReopenAfterEscPreservesTabAndDrafts · testDraftsAreIndependent | 통과 | 핫키로 패널 열기, 본문에 바로 커서, IME 조합 중 ⌘Return 처리 순서(마지막 글자), 저장 후 이전 앱으로 복귀, 연타 때 UI에서 중복 저장 방지 |
| ② 어제 한 일을 오늘 입력 | **testYesterdayWorkEnteredTodayLinksToYesterdayAndNextEntryStartsToday**(완료일이 어제로 기록되고 어제 DayBox에 연결됨, 저장 후 업무일이 오늘로 돌아오고 다음 메모는 오늘에 저장) · CaptureUXTests.testMemoSubmitResetsWorkDateAndFailureKeepsIt · testSessionPreservesPastDateAndStartsTodayAfterSave · testWorkDateLabelForTodayPastAndFuture · ReviewFixesTests.testConfirmCompletionSuccessResetsWorkDateToToday · TaskServiceTests.testCaptureMemoLateEntryBelongsToWorkDate | 통과 | 과거 날짜 배지(주황, 시계 아이콘)와 "오늘로" 버튼이 보이는지, 날짜 선택 컨트롤 조작 |
| ③ 기존 업무에 진행 기록 추가 | **testExistingTaskSelectionDefaultsToProgressRecordAndKeepsStatus**(기존 업무를 고르면 기본 동작이 진행 기록 추가, 특정 프로젝트 범위로 저장, 상태와 업무 수는 그대로) · CaptureUXTests.testExistingTaskActivityRestrictsProjectsAndTags · testExistingTaskActivityRejectsUnlinkedSelectionAndPreserves · TaskServiceTests.testAddActivityAppearsOnceOnItsDateAndDoesNotChangeStatus · TaskProjectUXTests.testActivityScopeCommonAndProject | 통과 | 업무 검색 필드 키보드 선택, 범위(공통/프로젝트) 선택 UI |
| ④ 일부 프로젝트만 완료해도 Task 전체 상태 유지 | TaskProjectUXTests.testProjectStatusSummaryLeavesOverallStatusUnchanged · testChecklistSummaryAndAllDoneKeepsTaskOpen · testCompletionScopeLinesShowRemainingRange · TaskServiceTests.testPerProjectStatusesAreIndependent · testAllProjectsCompletedDoesNotCompleteTask · testCancellingOneProjectLeavesOthersAndTaskUnchanged · PresentationTests.testProjectAndChecklistChangesNeverCompleteGlobalTask | 통과(기존 테스트로 충분해 새 테스트를 만들지 않음) | "G에 적용 완료"와 "Task 전체 완료" 버튼이 구분되어 보이는지, 확인 시트가 한 번만 뜨는지 |
| ⑤ 검색 → 원문 보기 → 검색 상태 복원 | **testSearchOpenOriginalThenRestoreKeepsQueryFiltersAndSelection**(원문을 읽어도 snapshot이 그대로, 새 결과가 생겨도 복원 후 선택 유지, AI 호출 0) · SearchUXTests.testSnapshotRestoreRoundTripsFiltersAndSelectionWithoutAI · testSelectionKeptWhenSameHitRemainsAndClearedWhenGone · testMoveSelectionFromNilAndClampsAtEnds · testTogglePreviewRequiresSelection | 통과 | 원문 sheet를 닫은 뒤 스크롤 위치 복원, 패널을 닫았다 다시 열 때 상태 유지, ↑↓/Space/Return 키 처리 |
| ⑥ 성과 질문을 건너뛰고 주간보고 복사 | ReportsUXTests.testSkippingAllQuestionsDoesNotBlockCopyOrConfirm · testQuizShowsOneAtATimeAndAdvancesAfterRecord · testMarkCopiedDoesNotChangeVersionState · testConfirmMessageAndStateLabel · ReportsPlanPresentationTests.testQuizAnswerAndSkipAreRecordedForPriorPeriodWithoutChangingSubmission · **testOfflineAIKeepsLocalCaptureSearchAndEditedReport**(복사 후에도 상태는 `edited`) | 통과 | ⇧⌘C로 실제 클립보드에 복사, 질문 카드 UI, "n개 남음" 표시 |
| ⑦ AI 재생성이 편집본·확정본을 덮어쓰지 않음 | ReportsUXTests.testRegenerationKeepsEditedDisplayAndDefersNewVersion · testDismissLeavesDisplayedVersionAndKeepsNewVersionInHistory · testConfirmedDisplayIsPreservedAndReadOnly · testSelectingAnotherVersionClearsPending · testLineDiffMarksSameAddedRemoved · ReportsPlanPresentationTests.testUnstoredEditsSurviveReloadAndPreventRegeneration · testStaleWarningAndNewVersionPreserveConfirmedBody · **testOfflineAIKeepsLocalCaptureSearchAndEditedReport**(AI 실패 재생성에서도 편집본 id·본문·DB 상태 유지) | 통과 | 변경 비교(ReportDiffView) 표시, "새 초안 적용/닫기" 버튼 조작 |
| ⑧ Secret 보기·복사와 표 편집 분리 | SecretSettingsUXTests.testReadStateFocusMoveNeverCopiesAndFocusedCopyCopiesOnce · testCopyFocusedRowIgnoredWhileEditing · testCancelEditingRestoresOriginalsAndClearsPreview · testEditingStateTransitions · SecretEditorOwnershipTests(4개) · **testSecretFlowTrimOnSavePartialEditRevisionTrashAndConcealedFeedback**(포커스만으로는 복사 안 됨, 명시 실행으로만 복사) | 통과 | 행 클릭/Return으로 복사, 편집 중 셀 선택, Tab/⇧Tab 이동, hover 때 값 비노출 |
| ⑨ Secret trim·부분 수정·이전 버전·휴지통 복원, 가림 문자 거부 | **testSecretFlowTrimOnSavePartialEditRevisionTrashAndConcealedFeedback**(입력 중에는 trim하지 않고 저장할 때 앞뒤만 trim, 내부 공백·개행·대소문자 보존. 부분 수정 시 다른 행의 id·값 유지, v1→v2. `••••••` 거부 시 다른 행·저장본 유지. v1 복원은 v3로 저장. 휴지통 복원 후 행·버전 유지, 다시 열면 값 가림) · SecretNormalizerTests(trim·부분 수정·key1/key2·붙여넣기) · SecretVaultTests.testPartialUpdateFixtureScenario · testTrashAndRestore · testDuplicateKeyRejectedAndNothingSaved · SecretsSettingsBackupPresentationTests.testRevisionRestoreTrashRestoreAndPurge · ReviewFixesTests.testShortBulletMaskIsRejectedAndInputPreserved · testRejectionPreservesOtherRowsAndNotifiesOnlyMaskedRow · SecretSettingsUXTests.testMaskedOnlyValueIsNotSavedAndOtherRowsPreserved | 통과 | 인라인 경고 위치(중복 key, 가림 문자), 붙여넣기 미리보기 UI, 기기 인증 프롬프트 |
| ⑩ 긴 한국어·오프라인 | **testOfflineAIKeepsLocalCaptureSearchAndEditedReport**(400줄 한국어 메모를 그대로 저장하고 검색됨. AI 네트워크 실패 시 결과·선택 유지, 문구 "AI 답변을 만들지 못했습니다. 잠시 후 다시 요청하세요." 자동 초안은 AI 호출 없이 생성) · **testAIUnconnectedStillAllowsFirstMemoSearchAndDraft**(AI 미연결 상태에서 첫 메모·검색·기록 기반 초안 동작) · SecretSettingsUXTests.testRecoveryMessages · testAIConnectionSummaryReflectsRuntimeRunner · SearchIndexTests.testSEARCH_T02_KoreanEnglishSymbolsAndAndQuery · testSEARCH_T03_ShortKoreanTermsUseLikePath · ReportServiceTests.testAIPayloadOmitsRunTimestampsAndFailureIsNotAutoRetriedWhenUnchanged | 통과(Core) | 좁은 창(840pt)·980pt 레이아웃 전환, 긴 한국어 줄바꿈과 잘림, 키보드 전용 조작, 오프라인 배너 표시 |

Core에서 결함이나 실패한 재현은 발견하지 않았다.

알려진 차이:
- Secret 복사 피드백(`SecretsModel.copyRow`)의 문구 "복사했습니다. 120초 후 같은 복사 항목이 남아 있을 때만 지웁니다."는 `ux-flows.md §3.8`의 예시("‘key’ 값을 복사했습니다 · 120초 후 클립보드 비움")와 다르다. 값을 노출하지 않으므로 보안 문제는 아니며, 현재 문구가 클립보드를 비우는 조건을 더 정확히 설명한다.

관찰 사항(결함 아님):
- ⑦의 화면 보존 로직(`ReportsModel.runGeneration`의 `preservesDisplay`)은 초안을 만든 주체(AI/결정적)와 상관없이 동작한다. 테스트한 경로는 결정적 재생성과 AI 실패 후 대체 경로다. 유효한 AI JSON으로 성공한 재생성 경로는 화면 보존 관점에서 별도로 테스트하지 않았다.

## 3. 보안 확인

| 항목 | 근거 | 결과 |
|---|---|---|
| Secret 제목·key·value가 일반 검색·AI 입력·work.sqlite에 들어가지 않음 | **testSecretTitleKeyAndValueNeverReachWorkDatabaseSearchOrAIInput**(SecretsModel로 저장·복사한 뒤 일반 검색 결과 0, AI 답변을 명시 실행해도 `MockAIProvider.receivedInputs`의 instructions·payload에 없음, work.sqlite(+wal/shm) 바이트에 없음, vault 파일에 평문 값 없음) · AcceptanceGapTests.testSEC_T26_SecretValueNotInGeneralSearchOrAI · testSEARCH_T08_SecretOnlySearchDoesNotCallAI · SecretVaultTests.testCanaryValuesAreNotPlaintextInDatabaseFiles | 통과 |
| Secret 경로에 네트워크·AI·로그 호출 없음 | `Sources/WorkLogCore/Secret`에서 `URLSession`, `import Network`, `NWConnection`, `AIProvider`, `aiRunner`, `AIJob`, `GroundedAnswer`, `print(`, `os_log`, `Logger(`, `NSLog`, `SearchIndex`, `repo.` 검색 → 주석 3줄 말고는 일치 없음. App의 `Secret*.swift`, `SearchSecretScope.swift`에서 `URLSession`, `AIProvider`, `groundedAnswers`, 로그 API 검색 → 일치 없음(SearchModel은 "사용하지 않음" 주석에만 등장) | 통과(정적) |
| 일반 검색·AI 코드가 vault를 참조하지 않음 | `Sources/WorkLogCore/Search`에는 "참조하지 않는다" 주석 1줄만 있음. `Sources/WorkLogCore/AI`, `Reports`, `Storage`에는 vault 타입 사용 없음(주석만) | 통과(정적) |
| 복사·저장 피드백에 값이 없음 | **testSecretFlowTrimOnSavePartialEditRevisionTrashAndConcealedFeedback**(저장, 복사, 거부, 복원, 휴지통의 모든 `message`에 값이 포함되지 않음) · VaultSessionTests.testDuplicateKeyErrorHidesKeyString · SecretsSettingsBackupPresentationTests.testAuthenticationFailureNeverEchoesAuthenticatorError | 통과 |
| 가린 값이 화면·접근성에 노출되지 않음 | 정적: `SecretViewerTable.swift:41-45`, `SecretsScreen.swift:245-247`은 `showsValues`가 켜졌을 때만 `Text(row.value)`를 그린다. 접근성 라벨은 "값 가려짐"/"가려진 값"(`SecretViewerTable.swift:51`, `SearchSecretScope.swift:173`, `SecretEditorView.swift:76,129`) | 정적으로만 확인. VoiceOver 실제 동작은 확인하지 않음(§4) |

## 4. 검증하지 않은 항목(실제 Mac 필요)과 수동 재현 절차

아래 항목은 이 환경에서 **실행하지 않았다.** 확인할 때는 가짜 데이터만 쓴다(회사 기록이나 실제 Secret 금지). 스크린샷은 가짜 데이터로 실제 실행한 화면만 남긴다.

| 항목 | 상태 | Mac 수동 재현 절차(요약) |
|---|---|---|
| IME: 한글 마지막 글자 | 미검증 | TextEdit에 포커스 → 입력 핫키 → 한글 IME로 "배포 완료"를 입력하고 '료' 조합 중에 바로 ⌘Return → 오늘 화면에서 본문이 "배포 완료"인지(마지막 글자 유실·중복 없음) 확인. 자동완성이 열린 상태(`@프`)에서 Return/Esc도 같은 방법으로 확인 |
| 이전 앱 복귀 | 미검증 | Safari를 맨 앞에 둔 채 입력 핫키 → 저장(⌘Return) → Safari가 다시 맨 앞에 오는지 확인. Esc로 닫을 때와 검색 패널 Esc도 같은 방법으로 확인 |
| 포커스 | 미검증 | 패널을 열면 본문에 커서가 있는지, 검색 패널을 열면 검색 필드에 있는지, sheet를 닫은 뒤 원래 목록 행에 포커스가 돌아오는지 확인. 메인 검색 화면에서 ⌘1/⌘2가 화면 이동으로 동작하는지(검토 M #1 수정 확인) |
| VoiceOver(가린 Secret 값 비노출) | 미검증 | ⌘F5로 VoiceOver 켜기 → Secret 화면에서 가짜 항목 열기 → VO+→로 행을 차례로 읽을 때 "key, 값 가려짐"만 읽히고 값은 읽히지 않는지 확인. 편집 모드 SecureField, 검색 패널 Secret 범위, 이전 버전 행도 확인 |
| 키보드 전용 조작 | 미검증 | 마우스 없이 Tab/⇧Tab/↑↓/Return/Space/Esc만으로 세 핵심 여정(Memo 저장, 검색→원문, 주간보고 후보 확정→복사)을 끝까지 할 수 있는지 확인. ↑↓만으로 Secret이 복사되지 않는지도 확인 |
| 텍스트 크기 | 미검증 | 시스템 설정 > 손쉬운 사용 > 디스플레이 > 텍스트 크기 최대 → 오늘, 업무, 주간보고, Secret 화면에서 글자가 잘리거나 겹치는지, 필수 버튼이 계속 보이는지 확인 |
| Reduce Motion | 미검증 | 손쉬운 사용 > 디스플레이 > 동작 줄이기 켬 → 패널 열기·닫기, 사이드바 접기, sheet 전환에서 슬라이드·확대 애니메이션이 없거나 줄어드는지 확인 |
| 대비 | 미검증 | 대비 증가 켬 + 라이트/다크 각각 → 상태 배지(아이콘+라벨), 포커스 링, 과거 날짜 배지, 보조 텍스트를 읽을 수 있는지 확인 |
| 840pt / 980pt 레이아웃 | 미검증 | 메인 창 너비를 840pt와 980pt 이상으로 바꿔 가며 오늘 화면이 3열 ↔ 세그먼트 전환되는지 확인. 전환해도 선택 영역·선택 항목이 유지되는지, 사이드바를 펼친 상태에서 콘텐츠 폭 기준이 맞는지(검토 M #2 수정 확인) 확인. 긴 한국어 업무명(80자 이상)의 줄바꿈도 확인 |
| 스크린샷 | 미검증(없음) | 가짜 데이터로 실행한 앱의 주요 화면(빠른 입력, 오늘 3열/좁은 창, 업무 상세, 검색+원문, 주간보고, Secret 조회/편집, 설정)을 라이트·다크로 캡처. 회사 기록·실제 Secret·인증정보가 화면에 없는지 확인한 뒤 저장 |
| 그 밖의 UI 확인(검토 M 전달) | 미검증 | sheet를 닫은 뒤 DayScreen 스크롤 복원(검토 M #8), 캡처 패널이 키 창일 때 ⌘N/⌘F 동작(#5, #6), 주간보고 화면 재조회 중복(#7) — 실제 앱에서 조작해 확인 |

## 5. 후속 키보드·검색 개선(request-2)

대상: 브랜치 `wlog-uxfl/uxfl-e55a-kbd-polish`, 커밋 `e2fb7ba`(기준 `2bc2a3e`). 검증자 Z, 2026-10-06 10:05–10:16 KST 실행.
기준: `request-2.md` 요청 1~5, `docs/ux-flows.md` §3.1·§3.5, 검토 V·W 최종 보고, 작업 X 결과.

**범위 한계.** §1~§4와 같다. Linux(aarch64)에서는 `WorkLogApp`을 구문 파싱만 할 수 있다. 아래 "통과(코드)"는 해당 코드 경로가 있고 Linux 구문 검사와 macOS CI 타입 검사를 통과했다는 뜻이다. 실제 Mac에서 키를 눌러 본 결과는 아니다. "통과(Core)"는 XCTest로 동작을 확인했다는 뜻이다.

### 5.1 실행한 검증

| # | 명령 | 환경 | 결과 |
|---|---|---|---|
| 1 | `swift build --build-tests` | Linux aarch64, Swift 6.3.3 | exit 0 (Build complete) |
| 2 | `swift test` (전체) | 같음 | exit 0 · **771개 실행, 실패 0** (0 unexpected), 53.7초. 765(§1) + `CaptureReopenTests` 6개 |
| 3 | `swiftc -frontend -parse -target arm64-apple-macos14 Sources/WorkLogApp/*.swift` | 같음(macOS SDK 없음) | exit 0 · 구문 파싱만 |
| 4 | `git diff --check 2bc2a3e..HEAD` | 같음 | exit 0 · 공백 오류 없음 |
| 5 | 정적 grep(§5.3) | 같음 | 아래 참고 |
| 6 | macOS CI (GitHub Actions "macOS build") | GitHub macOS 러너 | run `37397373881`, head `e2fb7ba`, **completed · success**(10:05:21–10:12:07 KST). job `build-and-test`의 모든 단계 성공: Test release tooling · Build all targets (including WorkLogApp) · Test WorkLogCore · Package unsigned DMG · upload-artifact. 검증자가 공개 GitHub REST API(`/actions/runs/37397373881`, `/jobs`)로 직접 확인함(`gh`는 이 환경에서 미인증이라 사용하지 않음). 직전 run `37337845635`(`3195316`)도 success |

- 관련 테스트 스위트는 모두 2번 실행에서 통과했다: `CaptureReopenTests`(6), `CaptureUXTests`, `CaptureSessionTests`, `TaskServiceTests`, `UXFlowVerificationTests`, `HotkeyBindingTests`(21), `HotkeySettingsCoordinatorTests`(25), `SettingsHotkeyValidationTests`, `SearchUXTests`, `AcceptanceGapTests`, `SecretVaultTests`.
- 이 브랜치에서 Core 변경은 `CaptureSessionModel.swift` 하나다(`git diff --stat 2bc2a3e..e2fb7ba`). 나머지는 `#if os(macOS)` 앱 코드와 문서다.
- 검증 중 다른 작업(AA)이 같은 브랜치에 `44c91ba`(`ProjectsScreen.swift`만 변경, Core·테스트 변경 없음)를 커밋했다. 이 커밋은 구문 파싱(exit 0)과 `git diff --check e2fb7ba..44c91ba`(exit 0)만 확인했고, macOS CI·요청별 근거 확인은 하지 않았다. 아래 줄 번호는 `e2fb7ba` 기준이다(`ProjectsScreen.swift`의 `WorkLogSourceRowStyle` 사용 위치는 `44c91ba`에서 `:91`, `:149`).

### 5.2 요청별 결과

| 요청 | 확인 방법·근거 | 결과 |
|---|---|---|
| 1. Task 등록 상태 키보드 선택 | **↑↓**: 02열이 펼침 없이 상태 5개를 항상 보여 주고 `actionKeys`에 `initial:<status>` 5개가 포함됨(`CapturePanel.swift:830`, 행 `:990-997`). `actionRow`의 `.onKeyPress` ↑↓ → `moveAction`(`:1031-1043`, `:1242-1246`). **Space/Return**: `captureFocus(action:)`(`:76-82`, 한글 조합 중·수정키 조합은 무시) → `chooseAction` → `model.initialStatus = status`(`:1229-1233`). **⌥1–5**: `KeyboardPanel.sendEvent`가 ⌥+키코드 18/19/20/21/23을 `TaskStatus.allCases[index]`로 전달(`:311-315`), 업무 탭에서만 연결(`statusHandler`, `:534-537`) → `selectStatus`(`:601-609`). **완료=완료일 작업일**: 새 업무는 `CaptureModel`이 `createTask(initialStatus:workDate:)`(`CaptureModel.swift:481`), 기존 업무는 `completeTask(workDate:)`(`:432`, `:560`). 테스트: TaskServiceTests.testCreateCompletedTaskHasNoStartedOnAndOneCompletionDate(완료일=workDate, 시작일 없음) · UXFlowVerificationTests.testYesterdayWorkEnteredTodayLinksToYesterdayAndNextEntryStartsToday(어제로 완료 등록) · CaptureUXTests.testRegistersAsCompletedSavesCompletedTask · PresentationTests.testTaskCreationDoesNotInventStartDate | 통과(Core: 완료일) · 통과(코드: 키 경로) · 실제 키 입력은 미검증 |
| 2. Secret 기본 검색 포함·키보드 열기/복사 | **기본 포함**: 범위 기본값 `.all`(`SearchScreen.swift:12`), 결과 목록에 `scope != .records`이면 Secret 제목 포함(`:219-220`), 제목 검색은 `environment.vaultSession.searchTitles`(vault, `:233-244`). **키보드**: ↑↓가 기록·Secret 섹션을 넘어 선택(`:358-368`), Return → `requestSecret` → 필요 시 인증 → key 목록·첫 key 자동 선택(`:269-309`, 모든 종료 경로 `defer`로 진행 상태 해제 `:281`). key 목록에서 ↑↓는 선택만(`:342-350`), Return만 `copyRow`(`:351-355`), Esc/⌘←로 결과 복귀(`:339-341`). 패널 ⌘1/⌘2/⌘3 = 전체/기록/Secret(`:325-332`). **Secret 범위 AI 차단**: `askAI()` 가드 2곳(`:312`, `:317`), ⌘Return 가드(`:334`), AI 버튼은 `scope != .secret`일 때만 표시·Secret 선택 시 비활성(`:557-563`), 범위 전환 시 Secret 검색어 분리 보관(`:59-70`). 유출 금지는 §5.3 | 통과(코드·정적) · Core 경계 테스트 통과(§3 테스트 재통과) · 실제 키 입력·인증 프롬프트는 미검증 |
| 3. 검색 전역 핫키 | **등록**: `AppController` 시작 시 `GlobalHotkeys(handlers: [.capture: showCapture, .search: showSearch])` → `HotkeySettingsCoordinator.start(capture:search:)`(`AppController.swift:85-93`). `GlobalHotkeys.register` → `RegisterEventHotKey`(서명 'WLOG', `hotKeyID`), 실패 시 "등록 실패: 다른 앱이 사용 중일 수 있음 (OSStatus n)"(`GlobalHotkeys.swift:58-86`). **디스패치**: Carbon 핸들러 `kEventHotKeyPressed` → 서명 확인 → `dispatch(id)` → 최근 눌림 HH:mm:ss(주입 Clock·업무 시간대) 기록 후 핸들러 호출(`:114-148`). `showSearch` → `SearchPanelController.show()` → `activate` + `orderFrontRegardless` + `makeKeyAndOrderFront` + 검색 포커스(`AppController.swift:178-193`, `SearchPanel.swift:37-58`). **진단**: 메뉴바 "검색 열기 (현재 단축키)" + 등록 상태·최근 눌림(`WorkLogApp.swift:61-78`), 설정 화면 같은 정보(`SettingsScreen.swift:92-97`). 진단은 메모리 전용, 검색어·Secret 미포함. Core: HotkeyBindingTests(`ctrl+opt+d` 파싱 등 21개), HotkeySettingsCoordinatorTests(25개) | 통과(코드·Core) · **실제 핫키 수신은 미검증(Mac 필요)** |
| 4. 선택 스타일(사이드바·업무 목록·프로젝트 목록) | 공용 `WorkLogSourceRowStyle`(`AppTheme.swift`): 선택은 `accentSoft` 채움, 포커스·대비 증가 때만 2pt 링, 호버는 약한 채움. 카드 테두리 없음. 사용처: 사이드바 `AppRootView.swift:209`(이전 행별 테두리 배경 제거), 업무 목록 `TaskListScreen.swift:32-34`, 프로젝트 목록 `ProjectsScreen.swift:73`, 프로젝트 업무 `:131`. 세 화면 모두 `List(selection:)`(전체 폭 파란 블록) 미사용(grep 0건). 상태 배지는 반투명 캡슐(`Components.swift` StatusBadge, 대비 증가 때만 테두리), 상태 심볼은 공용 `badgeSymbol`로 통일(예정=`circle.dashed`, 빠른 입력 `CapturePanel.swift:1197-1199`도 같은 값). 빠른 입력 02열 "등록 상태"는 펼침 목록이 아닌 항상 보이는 행으로 변경 | 통과(코드) · 실제 렌더링·대비는 미검증 |
| 5. 재열기 시 기본 유형 | `CaptureSessionModel.beginSession()`이 열 때마다 `tab = settings.defaultCaptureKind`, 초안은 보존(`CaptureSessionModel.swift:63-77`), 앱은 패널 표시 때 호출(`CapturePanel.swift:156`). CaptureReopenTests 6개 통과: testReopenAfterEmptyTaskTabStartsAtDefaultMemo · testReopenWithTaskDraftStartsAtMemoAndKeepsDraft · testReopenAfterSaveResetsSession · testDefaultTaskSettingStartsAtTask · testChangingDefaultKindAppliesOnNextOpen · testHasDraftCriteria | 통과(Core) |

발견한 결함: 없음(Core·정적 범위). 문서 차이 1건:
- `docs/ux-flows.md` §1 표 ② 행은 "Secret은 ⌘2(Secret 범위)"라고 적혀 있으나 코드(`SearchScreen.swift:327-329`)와 같은 문서 §3.5는 ⌘3=Secret, ⌘2=기록이다. 문서 정정 필요(검증자 수정 범위 밖).

### 5.3 Secret 경계 정적 확인(request-2 범위)

| 확인 | 명령/근거 | 결과 |
|---|---|---|
| Core 검색·AI·저장·보고가 Secret 타입·vault를 참조하지 않음 | `grep -rnE 'SecretRow\|SecretPayload\|SecretMetadata\|VaultSession\|SecretVault\|vaultSession\|VaultSchema' Sources/WorkLogCore/{Search,AI,Storage,Reports}` → `AI/AIProvider.swift:4` 주석 1줄만 | 통과(정적) |
| Core Secret 경로에 네트워크·AI·로그·검색 인덱스·work 저장소 호출 없음 | `grep -rnE 'URLSession\|import Network\|NWConnection\|AIProvider\|aiRunner\|AIJob\|GroundedAnswer\|print\(\|os_log\|Logger\(\|NSLog\|SearchIndex\|SearchModel\|repo\.' Sources/WorkLogCore/Secret` → `SecretModels.swift:3` 주석 1줄만 | 통과(정적) |
| 앱 검색·Secret·핫키·빠른 입력 파일에 로그·네트워크 호출 없음 | `SearchScreen/SearchPanel/SearchSecretScope/Secret*/GlobalHotkeys/CapturePanel.swift`에서 `print(\|os_log\|Logger(\|NSLog\|URLSession\|AIProvider` → 일치 없음(exit 1) | 통과(정적) |
| SearchModel(→SearchIndex·AI)에는 사용자 입력 검색어만 들어감 | `SearchScreen.swift`의 `model.text =` 대입은 `:227`(`scope != .secret`일 때), `:314`(`askAI`, Secret 범위·선택 가드 뒤) 두 곳뿐이며 둘 다 `query`(사용자 입력)만 대입. Secret 제목 결과는 App `@State secretTitles`에만 보관 | 통과(정적) |
| work.sqlite·일반 검색·AI 입력에 Secret 없음(실행) | §3의 UXFlowVerificationTests.testSecretTitleKeyAndValueNeverReachWorkDatabaseSearchOrAIInput · AcceptanceGapTests.testSEC_T26 · testSEARCH_T08 · SecretVaultTests.testCanaryValuesAreNotPlaintextInDatabaseFiles가 5.1 #2에서 다시 통과 | 통과(Core) |

### 5.4 Mac 수동 확인 체크리스트(가짜 데이터만)

준비: 새 사용자 계정 또는 빈 데이터 폴더, 가짜 업무("테스트 배포 점검"), 가짜 프로젝트("샘플A"), 가짜 Secret("테스트 계정" / key `user`, value `fake-123`). 회사 기록·실제 Secret·Keychain 항목은 쓰지 않는다. 스크린샷에 실제 값이 없는지 확인한다.

| # | 항목 | 절차 | 기대 결과 | 상태 |
|---|---|---|---|---|
| M1 | 빠른 입력 전체 키보드 조작 | 마우스를 쓰지 않는다. ⌃⌥Space → 메모 탭에서 시작하는지 확인 → ⌘2 → 업무명 입력 → Return(02열) → ↓로 "등록 상태" 행 이동 → Space로 "완료" 선택 → → (03 본문) → 본문 입력 → ⌘← 로 02열 복귀 → ⌥2(진행) → ⌥4(완료) → Tab으로 @프로젝트 → ⌘⇧P 피커에서 ↑↓·Return → ⌘D로 날짜를 어제로 → ⌘Return | 모든 단계가 키보드만으로 가능. ⌥숫자가 본문에 문자를 넣지 않음. 저장 후 업무 상세의 완료일이 어제, 다음 열기는 오늘·메모 탭 | 미검증 |
| M2 | Space/Return 이중 발화(검토 W C4) | 업무 03열 "관련 기록"·"프로젝트별 상태 관리" 펼침 헤더에 Tab으로 포커스 → Space 1회, Return 1회씩 누름. 02열 상태 행에서도 Space/Return 1회 | 헤더는 1회 누를 때마다 정확히 한 번 펼침↔접힘(두 번 토글되어 제자리로 돌아오면 결함). 상태 행은 한 번 선택되고 비프음 없음 | 미검증 |
| M3 | 검색 ⌃⌥D 원인 구분 | ① 메뉴바 아이콘 → "검색 열기 (⌃⌥D)" 클릭 → 패널이 맨 앞에 뜨고 검색 필드에 커서가 있는지(패널 표시 경로 확인). ② 설정 > 단축키 및 메뉴바에서 검색 단축키 상태가 "등록됨"인지, "등록 실패 … (OSStatus n)"인지 확인. ③ 다른 앱(Safari)을 앞에 둔 채 ⌃⌥D → 설정/메뉴바의 "최근 눌림 HH:mm:ss"가 갱신되는지 확인 | ①만 실패 → 패널 표시 결함. ② 등록 실패 → 다른 앱이 같은 조합 점유(조합 변경). ②는 등록됨인데 ③에서 '최근 눌림'이 갱신되지 않음 → 키가 앱에 도달하지 않음(다른 앱·시스템 단축키·입력기 충돌 의심, 해당 앱 종료 또는 조합 변경 후 재확인). ③ 갱신되는데 패널이 안 뜸 → 디스패치 후 표시 경로 결함 | 미검증 |
| M4 | 검색 전체 키보드 조작 | ⌃⌥D → "테스트" 입력 → ↓로 기록 결과에서 Secret 섹션까지 이동 → Return(인증 프롬프트 1회) → key 목록에서 ↑↓ → Return 복사 → Esc로 결과 복귀 → ⌘3(Secret 범위) → ⌘Return | ↑↓만으로 복사되지 않음, Return 때만 "복사했습니다…"(값 미표시). Esc 후 검색어·선택 유지. Secret 범위·Secret 선택에서 AI 버튼이 없거나 비활성, ⌘Return이 AI를 실행하지 않음 | 미검증 |
| M5 | VoiceOver 가린 값 | ⌘F5 → 검색 패널 Secret 결과 행과 key 목록을 VO+→로 읽음 | "Secret, 테스트 계정, …" / "user, 값 가려짐"만 읽히고 `fake-123`은 읽히지 않음 | 미검증 |
| M6 | 840pt / 980pt | 메인 창 너비 840pt와 980pt에서 사이드바·업무 목록·프로젝트 목록 확인. 빠른 입력 패널 폭을 넓혔다 좁혀 업무 3열 ↔ 세로 스크롤 전환 확인(콘텐츠 880pt 기준) | 선택 행이 전체 폭 파란 블록이 아니라 옅은 채움, 포커스 때만 링. 사이드바 항목에 카드 테두리 없음. 상태 배지는 옅은 캡슐. 전환 중 선택 유지, 긴 한국어 업무명 줄바꿈 | 미검증 |
| M7 | 재열기 기본 유형 | 업무 탭에 초안을 남기고 Esc → 다시 ⌃⌥Space | 메모 탭으로 열리고 업무 탭에 "초안 있음" 점 표시, ⌘2로 초안 이어 쓰기 가능 | 미검증(Core는 통과) |
| M8 | 대비 증가·다크 | 손쉬운 사용 > 대비 증가 + 다크/라이트 → M6 화면 | 선택 행에 2pt 링, 배지 테두리, 텍스트 판독 가능 | 미검증 |

### 5.5 미검증 목록
- macOS 실제 앱 실행: 전역 핫키 실수신(⌃⌥Space·⌃⌥D), 패널 전면 표시·포커스, 키보드 전용 흐름, Space/Return 이중 발화, IME 조합 중 키 우선순위, 인증 프롬프트, 클립보드 복사, VoiceOver, 대비·다크, 840/980pt 렌더링. 위 M1~M8 절차로 확인한다.
- macOS CI는 빌드·타입 검사·Core 테스트·DMG만 한다. UI 자동 조작은 포함하지 않는다.
