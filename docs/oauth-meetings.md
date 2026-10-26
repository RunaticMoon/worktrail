# ChatGPT OAuth와 로컬 회의록 (0.11.0)

## 연결 방식과 Enterprise 확인

WorkLog macOS 앱은 사용자의 Codex CLI를 실행하지 않고 공식 **Sign in with ChatGPT** 공개 로컬 앱 흐름으로 연결한다. 설정에서 브라우저 로그인을 시작하며, 기존 Codex 인증 파일을 가져오지 않는다. 기존 `codexExecutablePath` 설정은 호환성을 위해 읽되 앱 실행 경로로 사용하지 않는다. 개발 CLI의 기존 app-server 어댑터와 프로토콜 회귀 테스트는 유지한다.

AI 사용을 꺼 둔 상태로 시작했다면 설정에서 켜고 저장한 뒤 앱을 다시 연다. 계정 전환·로그아웃은 진행 중 요청을 취소하며, 이전 계정에서 제출한 대기 작업도 새 계정으로 실행하지 않는다.

2026-10-26 확인한 [공식 Quickstart](https://developers.openai.com/siwc/quickstart)는 eligible Plus·Pro 사용자의 플랜 사용과 공개 소스 앱 흐름을 명시한다. **Enterprise의 이 외부 앱 플랜 사용 지원은 문서로 확인되지 않았다.** Enterprise에서 Codex 자체를 사용할 수 있다는 사실과 WorkLog의 직접 OAuth 추론 허용은 별개다. 앱은 지원을 추정하거나 회사 정책을 우회하지 않으며 로그인 동의 범위와 모델 조회·실제 요청의 허용 결과를 따른다. 실제 Enterprise 계정은 테스트하지 않았다.

[등록·로그인](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)에 따라 loopback `127.0.0.1` 콜백, PKCE S256, state, nonce, RS256 ID-token 검증을 적용한다. 발급받은 앱별 등록과 토큰은 WorkLog 전용 Keychain 항목에 저장한다. 일반 DB·설정·백업에는 넣지 않는다. ‘다른 계정으로 로그인’은 별도 등록을 만들며 로그아웃은 로컬 토큰을 제거하고 가능한 경우 서버 폐기도 요청한다.

[모델과 추론](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)의 `/v1/models`, `/v1/responses`를 사용한다. `store:false`, `stream:true`, 앱이 만든 텍스트 입력만 전송하며 도구를 제공하지 않는다. 서버의 완료 이벤트를 확인하고 기존 출력 검증을 통과해야 초안으로 사용한다. 비공식 ChatGPT backend-api나 Codex 토큰 복사 경로는 없다.

## 회의록 사용

사이드바 ‘회의록’ → ‘새 회의’에서 제목·업무일을 정하고 다음 중 하나로 전사를 작성한다.

- ‘한국어 모델 준비’로 필요할 때만 Apple 모델을 내려받는다.
- ‘녹음 시작’은 마이크 권한을 받은 뒤 이 Mac의 마이크로 녹음한다. ‘녹음 중지 후 전사’로 로컬 전사를 시작한다.
- ‘음성 파일 가져오기’로 로컬 음성 파일을 전사하거나, 전사문을 직접 붙여 넣는다.
- 직접 작성한 회의 메모와 날짜별로 선택한 기존 일반 메모를 함께 저장한다.
- ‘전사와 메모 요약’을 누르면 텍스트만 연결된 ChatGPT 계정으로 보낸다. 요약·결정 사항·할 일·확인할 사항을 초안으로 저장한다.

전사는 [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)·[SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)로 Mac에서 수행한다. 한국어와 기기 지원은 런타임에 검사하며 미지원 시 서버 STT로 대체하지 않는다. 모델 설치 전에는 전사를 시작하지 않는다. 녹음 중에도 메모를 작성할 수 있고, 편집은 잠시 입력을 멈추면 자동 저장한다. 화면을 나가거나 앱을 종료하면 녹음을 중지하고 저장한다. 전사 저장에 성공하면 녹음 파일을 삭제한다. 실패하거나 종료로 중단된 녹음은 앱 전용 폴더의 회의 연결 정보로 재시작 후 복구하여 다시 전사하거나 내보내고 삭제할 수 있다. 미전사 음성은 DB 백업에 포함되지 않는다. 가져온 음성 원본은 변경하지 않는다.

기존 메모는 선택 당시 원문·revision의 사본으로 보관한다. 원본 수정·삭제로 회의 근거가 바뀌지 않는다. 요약 항목은 입력의 유효한 출처와 원문 인용을 검사하지만, 내용의 의미상 정확성은 사용자가 검토한다. 전사·메모를 바꾸면 이전 요약은 오래된 초안으로 표시한다. AI 실행 중의 원문 변경·삭제·요약 편집을 감지하여 새 결과가 이를 덮어쓰지 않는다. 실패해도 이전 요약과 원문을 보존한다.

회의록은 검색·수정·휴지통 이동·복원·텍스트 내보내기를 지원한다. 회의록 내부 검색은 제목·전사·회의 메모를 대상으로 한다. 일반 검색/관계 그래프/주간보고의 근거로 자동 편입하지 않는다. 회의 데이터는 work.sqlite migration v5로 저장되어 기존 DB 백업·복원에 포함된다. Secret과 제출용/성과 리포트의 저장 계약은 바꾸지 않는다.

빈 제목·크기 제한·저장소 오류 등으로 편집을 저장하지 못하면 정상 앱 종료를 취소하고 회의록으로 돌아간다. 오류를 고쳐 저장한 뒤 종료할 수 있다. 강제 종료나 시스템 장애까지 편집 보존을 보장하지는 않는다.

요약 입력은 UTF-8 240KB, 출력은 64KB까지이며 넘으면 원문을 몰래 자르지 않고 안내한다. 전사 저장 자체는 2MB까지 가능하다.

## 검증과 제한

가짜 데이터로만 검증하며 실제 회사 기록·Codex 토큰·기존 Keychain 값은 읽지 않는다. macOS 기본 툴체인은 Swift 6.4/SDK 27이며 최소 배포 대상은 macOS 26을 유지한다. Linux Swift 6.3.3 검증과 macOS SDK/UI 검증은 각각 기록한다.

`bash scripts/maclab/run-meeting-stt-check.sh`는 가짜 한국어 합성 파일을 만들고 네트워크 차단 환경에서 전사·취소·외부 URL 거부를 검증한다. 실제 마이크 권한·녹음, 실제 OAuth 동의·토큰 발급, Enterprise 계정 추론은 이 자동 검증에 포함되지 않는다. 최신 검증 결과와 산출물은 PR 설명에 기록한다.

이번 작업의 화면·키보드 검증은 Mac 잠금으로 막힌 뒤 사용자 요청에 따라 후속 확인으로 남긴다. macOS 컴파일과 로컬 STT·녹음 복구 검증은 화면 검증을 대신하지 않는다.


## 배포·롤백

배포 대상은 `RunaticMoon/worktrail`의 GitHub Releases/Sparkle 업데이트 채널이다. M1의 `/Applications/WorkLog.app` 또는 `~/Applications/WorkLog.app`에서는 설치본을 확인하지 못했다. 승인 후 PR merge → 원본 main fast-forward pull/clean·원격 HEAD 확인 → 해당 merge SHA를 지정하여 `macos-release.yml`(tag `v0.11.0`, publish `publish`)을 실행한다. GitHub-hosted macOS 러너에서 고정 앱 서명·Sparkle 서명·DMG/feed 검증을 수행하고 공개 산출물을 다시 내려받아 체크섬·버전·서명·업데이터 로딩을 확인한다. 실제 회사 계정의 최초 로그인 동의와 사용자 설치본의 업데이트 재시작은 별도 사용자 확인이 필요하다.

롤백은 기존 `v0.10.4` 릴리즈를 보존하고 필요 시 최신 배포 표시를 이전 릴리즈로 되돌리는 방식이다. 이미 0.11.0을 설치했다면 0.10.4 앱을 직접 재설치하며, 데이터 복구가 필요한 경우 업데이트 전 백업을 별도로 보존하고 앱의 백업 복원 절차를 사용한다. OAuth 토큰은 백업 복원 대상이 아니며 신규 회의 테이블은 이전 앱에 표시되지 않는다. 새 회의 원문은 다운그레이드 전에 텍스트로 내보낸다.
