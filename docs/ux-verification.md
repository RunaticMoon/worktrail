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

## 5. 콘텐츠 중심 UI 재설계 — Maclab 실행 검증 (2026-10-10)

이 절은 위 2026-10-05 Linux 검증 기록에 추가한 **실제 Mac 실행 결과**다. §1–4의 당시 미검증 표시는 이 절에서 확인한 항목에 한해서 갱신한다. 화면이 보이는지 확인한 결과와 저장·복사 등의 동선을 끝까지 수행한 결과를 구분한다.

### 대상과 데이터

- 변경 전: `2bc2a3e`. 최초 변경 후: `cd3df32`. 실행 중 발견한 창 너비 문제를 수정한 재검증 대상: `5720a4e`.
- Maclab 실행 `5b4e3453…`: 변경 전·후 macOS 빌드 및 최초 화면의 표시·배치 확인 통과. 종료 후 임시 환경 정리를 확인했고 최종 비용은 $0.20으로 정산됐다. 이 결과는 모든 사용 동선의 통과를 의미하지 않는다.
- 후속 실행 `3748b774…`는 `38c8583`에서 시작했다. 실제 사용 중 발견한 검색 패널 최초 표시 문제는 `62ad6c9`를 원격 Mac에서 다시 빌드해 확인했다. Task·검색·주간보고의 아래 동선 결과를 추가했으며, Secret과 데이터 양별 확인은 아직 완료하지 않았다.
- 실제 창 크기는 960×640, 1280×800, 1440×875였다. 1440×900을 요청한 경우 1440×900 Mac 데스크톱의 메뉴 막대 등 가용 영역 제한으로 높이가 875로 조정됐다. 1440×900 창을 그대로 검증했다고 보고하지 않는다.
- `DEBUG`의 `--ui-test-fixture empty|few|many`로 만든 가짜 데이터만 사용한다. 실행마다 새 임시 경로, 메모리 Vault 키, 가짜 기기 인증, 고정 시계와 순차 ID를 사용한다. 운영 데이터 경로·Keychain·Codex 제공자를 열기 전에 테스트 환경으로 분기한다. 보고서는 AI 없이 생성한다.
- `many` 데이터: Task 32개, 오늘의 여러 줄 Memo 36개와 지난주 Memo, 최대 4개 프로젝트 연결, 긴 한국어 업무명, 25개 key를 가진 가짜 Secret과 이전 버전·휴지통, 제출용 주간보고와 성과자료. `empty`/`few` 환경도 제공하지만, 제공 사실을 모든 창 크기에서 실행한 증거로 간주하지 않는다.

### 실제 화면에서 확인한 문제와 전후 차이

| 화면·크기 | 변경 전 실제 관찰 | 변경 후 실제 관찰·판정 |
|---|---|---|
| 오늘, 960×640 | 탭으로 한 영역을 표시한다. 바깥 카드, 별도 섹션 헤더와 제목별 버튼 테두리가 반복된다. **이 크기에서 3열을 표시한 것은 아니다.** | 한 목록 중심 구조로 변경했다. 최초 변경 후에는 긴 내용이 실제 가용 너비를 넘어가는 잘림을 발견했다. `5720a4e`를 Mac에서 다시 빌드하고 같은 작은 창을 확인해, 본문이 가용 너비 안에서 줄바꿈되는 것을 확인했다. |
| 오늘, 1280×800 | 타임라인·업무·메모가 거의 같은 너비의 3열이다. 각각 독립 스크롤을 가지며 업무·메모 항목 안에 배경 박스가 반복된다. 긴 업무명이 타임라인에서 말줄임된다. | 활동 기록·업무 상태·메모 중 필요한 목록 하나에 본문 폭을 배분하도록 변경했다. 탭마다 마지막 스크롤 항목을 보존하는 코드를 추가했다. 모든 탭 전환·스크롤 복귀 동선의 실제 검증은 별도다. |
| 주간보고, 1280×800 | 본문 시작이 화면의 약 y=440까지 내려가고, 우측 계획 영역이 약 340pt를 차지한다. 복사 버튼은 최초 화면에서 보이지 않는다. | 본문 시작이 약 y=260으로 올라왔다. 복사·저장·보고서 확정이 상단에서 보인다. 계획과 질문은 필요한 경우 펼친다. y 좌표는 해당 화면 관찰치이며 모든 크기의 고정 배치 규칙이 아니다. |
| 업무 목록 | 1280px 너비의 변경 전 화면에서 약 5개 행을 한 번에 확인했다. | 960px 너비의 변경 후 화면에서 약 7개 행이 보였다. 카드 제거에 따른 밀도 차이를 관찰했지만, 서로 다른 창 크기이므로 동일 조건의 정량 성능 비교로 보고하지 않는다. |
| 검색 패널 | 이번 재설계의 첫 실제 검색 동선에서 패널을 처음 열 때 내용이 투명하게 표시되는 문제를 발견했다. 변경 전·후 비교 수치로 취급하지 않는다. | `62ad6c9`를 실제 Mac에서 다시 빌드한 뒤 검색 결과 1개가 보이는 화면, 원문 열기, 검색 상태로 복귀를 확인했다. |
| Secret | 조회 대상이 없는 경우에도 상세 영역을 위한 공간이 필요했다. | 선택하지 않은 항목의 빈 상세 패널을 상시 띄우지 않는 것을 확인했다. 복사·부분 수정의 완료 여부는 별도의 실제 동선 결과로 판정한다. |

전후 화면 증거는 실제 실행 캡처만 사용한다.

| 비교 | 변경 전 | 변경 후 |
|---|---|---|
| 오늘 960×640 | [변경 전](../.build/maclab/evidence/before-day-960.jpg) | [너비 수정 후](../.build/maclab/evidence/after-day-960.jpg) |
| 오늘 1280×800 | [변경 전](../.build/maclab/evidence/before-day-1280.jpg) | [변경 후](../.build/maclab/evidence/after-day-1280.jpg) |
| 주간보고 1280×800 | [변경 전](../.build/maclab/evidence/before-weekly-1280.jpg) | [변경 후](../.build/maclab/evidence/after-weekly-1280.jpg) |
| 업무 목록 — 크기가 다른 참고 비교 | [변경 전 1280 너비](../.build/maclab/evidence/before-tasks-1280.jpg) | [변경 후 960 너비](../.build/maclab/evidence/after-tasks-960.jpg) |

작은 창 수정 후 확인 화면의 Maclab 증거 ID는 `b9f67de0-5cc5-4851-bac7-b347c174e16b`, 최종 빠른 입력 화면은 `cab0c041-64eb-4668-8ada-6269542f0bd8`다. 링크된 8개 이미지는 로컬 `.build/maclab/evidence/` 검증 산출물이며 저장소에 포함되지 않을 수 있다.

### 구현한 화면 구조와 크기 규칙

| 영역 | 제거·통합한 구조 | 현재 구조 |
|---|---|---|
| 공통·오늘 | 고정 사이드바 폭, 넓은 창의 동일한 3열, 카드 안 섹션 헤더·행 배경 | 사이드바를 조절·접을 수 있고, 주 콘텐츠는 실제 남은 창 크기를 사용한다. 오늘은 날짜와 기록 추가를 상단에 두고 활동 기록·업무 상태·메모를 전환한다. 상태만 유지된 날짜를 실제 활동으로 추가하지 않는다. |
| 빠른 입력 | 기본 본문 주변의 반복 안내와 펼쳐진 Task 옵션, 상태별 큰 선택 영역 | Memo 본문 우선, 프로젝트·태그·날짜는 보조 컨트롤. Task 모드의 선택과 추가 옵션은 필요한 경우 표시한다. 기존 초안·한글 조합 보호 경로를 유지한다. |
| 업무 | 업무마다 반복되던 카드·배지, 상세 속성별 큰 영역 | 업무명 중심의 행, 상태·마감은 보조 위치, 여러 프로젝트는 요약 표시. 상세에서 진행 기록 추가와 전체 상태 관리가 먼저 보이며 체크리스트·프로젝트 적용·근거는 펼친다. |
| 검색 | 필터·안내·AI 영역이 결과와 경쟁하던 배치 | 검색창과 결과 목록 우선, 필터는 작은 팝오버. 유형·날짜·일치 문맥을 같은 행에 표시한다. AI 답변은 명시적으로 펼치고 실행한다. |
| 주간보고·성과자료 | 상시 계획·질문 열, 본문 위 양식·AI 안내, 변경 비교의 내부 스크롤·행별 배지 | 보고서 본문에 전체 주 콘텐츠 폭을 사용하고 복사·저장·확정을 상단에 고정한다. 계획·질문·근거·작성 옵션은 펼치기, 성과자료는 기간·날짜·저장 보고서 선택을 상단에 모은다. 본문은 14pt, 읽기 영역은 최대 1120pt, 편집 높이는 창 높이에 따라 240–600pt 범위로 조절한다. |
| Secret | 항목별 카드, 선택 전 빈 상세, 조회·편집을 혼동시키는 행 동작 | 제목 목록과 key/value 표. 조회의 명시적 복사와 편집 전환을 구분한다. 값 가림, 저장 시 앞뒤 trim, 부분 수정·이전 버전·휴지통·백업은 유지한다. |

제품 데이터 모델과 저장 규칙을 바꾸지 않았다. 계획 포함과 실제 착수·완료, 프로젝트 적용 완료와 Task 전체 완료, 제출용 보고서와 성과자료, 복사와 확정은 각각 별도 동작으로 남아 있다.

### 핵심 동선: 구현 차이와 실제 검증 상태

| 동선 | 구현 차이 | 이 절 작성 시 실제 실행 판정 |
|---|---|---|
| 핫키 → Memo → 저장 → 이전 앱 | 가벼운 Memo 기본 화면, 본문 포커스와 저장 후 복귀 경로 유지. ⌘N이 기본 새 창 명령과 충돌하는 문제를 별도 수정했다(`33babb1`). | **실제 완주 통과.** 전역 핫키로 660×500 패널 열기, Memo 본문 포커스, 가짜 여러 줄 입력 일치, ⌘Return 저장 후 패널 닫힘과 이전 앱(TextEdit) 복귀를 확인했다. 별도의 ⌘N 실행에서도 추가 메인 창 없이 같은 크기의 입력 패널과 본문 포커스를 확인했다. 한글 IME 조합 중 저장은 미검증이다. |
| 기존 Task 찾기 → 진행 기록 | 행을 훑고 상세를 열면 진행 기록 입력과 상태 관리에 접근한다. 프로젝트·체크리스트 세부 영역을 먼저 거치지 않는다. | **실제 완주 통과.** 목록 행을 더블클릭하고 진행 기록을 작성·저장한 뒤 다시 열어 보존을 확인했다. 실제 클릭과 native Accessibility 검증을 함께 사용했다. |
| 검색 → 원문 → 검색 복귀 | 검색어·선택을 유지한 채 원문을 열고 결과 목록으로 돌아오는 구조. | **실제 수동 동선 통과.** 전역 검색 핫키 → 검색창 포커스 → 가짜 검색어 입력 → 결과 1개 확인 → ↓/Return으로 원문 열기 → Esc로 복귀 후 검색어·선택·포커스 보존을 확인했다. 스크롤이 0이 아닌 긴 결과 목록의 복귀는 미검증이다. 자동 helper의 검색어 전체 일치 검사는 강조 마크업 때문에 실패했으므로 자동화 전체 통과로 표현하지 않는다. |
| 주간보고 수정 → 계획 검토 → 복사 | 본문과 상단 복사 버튼을 처음부터 볼 수 있다. 계획은 필요할 때 펼치며 복사와 보고서 확정을 별도 라벨로 제공한다. | **실제 완주 통과.** 사이드바로 열기 → 가짜 한 줄 편집 → ⌘S 저장 → 계획 펼치기 → 본문 복사를 수행했다. 편집 보존, 복사한 본문과 편집 본문의 정확한 일치, 복사 뒤 미확정·편집 가능 상태 유지를 확인했다. 계획 데이터는 변경하지 않았다. 이미 생성된 미응답 질문 건너뛰기는 미검증이다. |
| Secret 검색 → 복사 → 일부 값 편집 | 제목 검색 후 표에서 복사하거나 편집으로 전환한다. 방향키 선택은 복사 동작과 분리한다. | **부분 통과.** 제목 클릭 후 명시적 복사, 방향키만으로 복사하지 않음, 편집 셀 클릭 시 복사하지 않음, 첫 값 수정·앞뒤 trim·둘째 값 보존·조회 복귀를 확인했다. 25개 key의 편집 화면에서 값 가림도 확인했다. Return으로 둘째 값을 복사하는 검사와 저장 후 가림 상태의 자동 검사는 실패해 재확인이 필요하며 전체 동선 통과로 처리하지 않는다. |

클릭 수·화면 전환 수의 동일 조건 전후 측정은 아직 완료하지 않았다. 상단 고정 버튼으로 없앤 스크롤 요구와 접기 구조는 구현 변화이며, 모든 동선이 더 적은 클릭으로 끝났다는 실측 결과로 바꾸어 표현하지 않는다.

### 실행한 검증과 남은 범위

| 검증 | 결과 | 범위 |
|---|---|---|
| Linux 전체 `swift test` | **765개, 실패 0** | Core와 기존 회귀 테스트. SwiftUI 렌더링을 검증하지 않는다. |
| 관련 UX·Presentation 대상 테스트 | **90개, 실패 0** | 상태·초안·검색·보고서·Secret 동작의 회귀 확인. |
| Mac 변경 전·후 빌드 | 통과 | 실제 macOS SwiftUI/AppKit 타입 검사·링크 포함. |
| Maclab 최초 표시·배치 확인 | 통과 | 실행 `5b4e3453…`. 저장·복사·IME 등의 전체 동선 통과를 뜻하지 않는다. |
| `5720a4e` Mac 재빌드와 오늘 960×640 재확인 | 통과 | 실제 가용 너비를 넘던 줄 잘림을 수정한 뒤 같은 작은 창에서 줄바꿈 확인. |
| 전역 핫키 Memo 저장·이전 앱 복귀 | 통과 | 실제 Mac 동선. 본문 포커스·여러 줄 입력·저장 후 닫힘·TextEdit 복귀를 확인했다. Maclab 출력 `5c5f0d0a-e9d3-4ed5-8aaf-d7b8e5795a97_stdout`. |
| 앱 내 ⌘N 빠른 입력 | 통과 | 추가 메인 창이 열리지 않고 660×500 입력 패널의 본문에 포커스가 놓이는 것을 확인했다. Maclab 출력 `3066abcb…_stdout`. |
| 검색 패널 최초 표시 문제 수정 후 Mac 재빌드 | 통과 | `62ad6c9` 원격 빌드 출력 `233afb26…_stdout`. 실제 검색 결과 표시·원문 열기·Esc 복귀를 이어서 확인했다. |
| Task 진행 기록 작성·저장·재열기 | 통과 | 실제 행 더블클릭 후 native Accessibility로 가짜 진행 기록 저장과 재열기 보존을 확인했다. |
| 검색 핫키·원문 열기·검색 상태 복귀 | 수동 통과 | 실제 키 입력과 화면으로 검색어·선택·포커스 복귀를 확인했다. 강조 마크업을 포함한 결과의 자동 문자열 판정은 실패했으며, 스크롤이 0이 아닌 위치의 복귀는 미검증이다. |
| 주간보고 편집·저장·계획 펼치기·복사 | 통과 | `scripts/maclab/report-flow.js`의 native Accessibility 동선을 실제 Mac에서 2.719초에 완주했다. 본문·클립보드를 출력하지 않고 일치 여부와 저장·확정 상태만 검증했다. Maclab 출력 `26e2bcfb-d7c7-41d4-bebd-855571ce0664_stdout`. 질문이 생성되지 않은 fixture에서 수행했다. |
| Secret 명시적 복사·부분 수정 | 부분 통과 | 명시적 복사, 방향키 선택 시 비복사, 편집 클릭 시 비복사, 앞뒤 trim, 미수정 값 보존을 확인했다. Return 복사와 저장 후 값 가림의 자동 판정이 실패한 원인은 아직 확정하지 않았다. |
| 가짜 fixture 생성·반복 실행 smoke | 통과 | `empty`/`few`/`many` 생성, Secret 가짜 행 수·trim·2개 버전·휴지통, AI 미연결 확인. `many` 두 번 실행 시 경로는 다르고 Task와 주간보고 본문은 동일함을 확인했다. Linux에서는 Pasteboard만 메모리 구현으로 대체했다. |

아직 미검증인 항목은 실제 한글 IME 조합 중 Enter/Esc/⌘Enter, VoiceOver의 가림 값 읽기, 대기 중인 성과 보충 질문을 건너뛴 실제 복사, 검색의 긴 결과 목록 스크롤 복원이다. Secret의 Return 복사와 저장 후 가림 판정은 추가 실행으로 확인해야 한다. 오프라인 fixture에서 질문을 생성하지 않고 복사하는 경우는 **이미 생성된 미응답 질문을 건너뛰는 시험과 다르다**. 키보드 전용 완주, 접근성 표시 설정 조합, 모든 창 크기 × 모든 데이터 양의 조합도 부분 화면 확인만으로 완료 처리하지 않는다.
