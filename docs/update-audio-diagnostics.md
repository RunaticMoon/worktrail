# 업데이트·녹음 안정성과 진단 리포트 (0.16.0)

## 사용자 동작

- 앱을 업데이트하고 열 때 Secret 키를 조회하거나 만들지 않는다. 자동 활동 수집과 예약 AI는 Keychain 접근 승인이 필요하면 인증창 없이 실패 상태를 남긴다. 사용자가 Secret 잠금 해제, 연결 확인, 지금 수집 등을 선택하면 정상 인증을 허용한다. 기존 키·ACL·암호화는 유지한다.
- 녹음 시작 뒤 지연된 구성 알림과 출력 장치 알림은 선택 마이크의 실제 ID·하드웨어 형식·tap PCM 형식을 비교해서 판단한다. 동일 입력인데 엔진만 멈추면 같은 입력으로 재시작한다. 새 PCM 없이 재시작이 반복되거나 실제 입력이 바뀌면 원본을 보존하며 중단한다. 임의 장치 전환은 없다.
- 설정 → **진단 로그** → **진단 리포트 저장…**에서 JSON 파일을 저장한다. 앱 저장소를 열지 못한 경우에도 도움말 메뉴의 같은 명령을 사용할 수 있다. 문제 발생 시각과 재현 순서를 파일과 함께 제출한다. 자동 업로드·외부 전송은 없다.

## 저장 범위와 개인정보

운영 로그는 ~/Library/Logs/WorkLog에 JSONL로 저장한다. 최근 7일, 파일당 1 MiB, 전체 10 MiB를 상한으로 사용하며 상한에 도달하면 오래된 파일을 삭제한다. 시작·기록·내보내기·현황 조회 및 실행 중 60초 유지보수에서 만료 내용을 제거한다. 앱이 꺼져 있는 동안에는 파일을 지울 프로세스가 없으므로 다음 실행 때 정리한다. 내보낸 리포트 파일은 사용자가 직접 관리한다.

기록 대상은 시작·종료, 업데이트 확인/발견/다운로드/실패, Keychain 숫자 OSStatus, 녹음 권한·장치 구성·재시작·중단, 저장·복구·전사·AI·활동 수집의 주요 결과다. 앱/macOS 숫자 버전을 이벤트에 포함하여 업데이트 전후를 구별한다. 로그 삭제는 업무·회의 원본을 건드리지 않는다.

일반 메모·업무를 포함한 work/vault DB의 open·prepare·bind·execute·step·backup 오류는 SQLite 숫자 코드만 공통 수집한다. 성공한 SQL마다 이벤트를 쌓지 않으며 SQL 본문·바인딩 값·DB 경로는 콜백에 전달하지 않는다.

허용된 enum과 숫자/boolean만 기록한다. 원문 오류 설명과 NSError.userInfo, 임의 domain, 장치명·UID, 사용자/계정, 파일 경로·URL, 메모·업무·전사·음성, Secret·자격증명은 로그에 넣지 않는다. 내보내기는 허용된 로그 필드를 다시 디코딩·인코딩하며 앱 DB·다른 파일·심볼릭 링크·하드 링크를 첨부하지 않는다. 디렉터리는 0700, 로그와 내보낸 파일은 0600이다.

디스크 오류는 앱 기능을 중단시키지 않고 상태 화면의 저장 불가/누락 이벤트 수로 표시한다. 이것은 운영 이벤트 리포트이며 네이티브 크래시 덤프나 모든 함수 호출을 수집하는 도구는 아니다.

## 근거

- 공개 v0.15.0 DMG의 고정 서명과 이전 개발용 ad-hoc 앱 구분: [배포 문서](RELEASE.md#업데이트-후-시작-시-keychain-창-방지).
- 설치 Apple SDK AVAudioEngine.h의 AVAudioEngineConfigurationChangeNotification 설명은 입력 또는 출력 형식 변화 시 엔진이 멈추고 노드/연결이 유지된다고 명시한다. 알림 자체는 마이크 변경의 증거가 아니다.
- 업데이트 이벤트는 [Sparkle 공식 delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)의 읽기 전용 결과 알림으로 기록한다. 설치한 패키지 버전은 2.10.0이며 업데이트 정책은 바꾸지 않는다.

## 검증

2026-10-28 KST, 실제 사용자 자격증명/마이크 없이 수행했다.

- M1 Apple Swift 6.4 / macOS SDK 27: swift build --build-tests 성공. 배포 최소 버전은 macOS 26.0 유지.
- macOS 전체 swift test: 최종 1,126개 통과(23:03 KST).
- 진단 저장소 11개: 보관 경계, 파일/총 용량, export 필드 정화, private 권한, 링크 제외, 저장 실패, 동시 기록, 불완전한 마지막 행 복구.
- 실제 앱 facade privacy 검사 4개: 합성 토큰·경로·오류 원문 제외, 숫자 상태 보존, 오류 종류 분류, 큐 순서·삭제 후 재기록.
- 합성 PCM audio 9 suites, recording session 15 suites, model 7 checks, tokenizer 3 checks 통과.
- 가짜 Keychain/백업 관련 지정 97개 테스트 통과. 사용자 Keychain을 읽거나 변경하지 않았다.
- 지연 키 초기화의 연관 회귀도 수정했다. 키를 만든 적 없는 빈 vault는 공식 스키마와 모든 관련 테이블이 빈 상태임을 검사한 뒤 기본 백업 복원을 허용한다. 키가 사라진 기존 vault와 손상/비어 있지 않은 vault는 계속 거부한다. 새 복원 테스트 3개와 기존 백업/지연 초기화 포함 26개 통과.
- SQLite 진단 콜백·개인정보 격리·AppEnvironment 연결 테스트 7개 통과.
- OAuth identity 7, loopback 3, 녹음 복구 8, 종료 8 checks 통과.
- 배포 Python 도구: 60개 중 55개 통과, 5개 skip(일회용 GitHub macOS 서명 검사 2개, 로컬 OpenSSL 3 부재 3개). 배포 CI에서 추가 실행한다.

격리된 DEBUG fixture에서 설정 검색·7일/용량/개인정보 안내, 실제 Tab → Return으로 리포트 저장 창 열기, /tmp JSON 저장(schema 1·이벤트 3개·7일·0600), Tab → Space 삭제 확인·Escape 취소·실제 삭제와 이벤트 0개 표시를 확인했다. 검사 스크립트는 scripts/maclab/diagnostics-ui-check.js이며 실제 inspect/export/delete가 통과했다. 신규 버튼은 키보드 activation이 동작하도록 focusable modifier 순서를 조정했다.

Linux Swift 6.3.3 arm64 컨테이너의 최종 전체 1,126개 테스트도 통과했다(23:05 KST, 90.184초). OCI 기본 Swift 실행기는 libxml2.so.2 누락으로 실패해 호스트 설정을 변경하지 않고 기존 swift:6.3.3-noble 이미지의 격리 컨테이너를 사용했다. 이미지 digest는 sha256:1038d54c80063f5cdfabc4560990c30af64b5de8ebf28161deb22ca4ad5db866이다. 실제 사용자 장치에서 업데이트 후 Keychain 경고가 사라지는지, 마이크 녹음이 지속되는지는 별도 사용자 환경 검증 항목이다.

## 배포와 복구

검토한 PR을 승인받은 뒤 merge → 원본 main fast-forward/clean/원격 HEAD 대조 → 그 merge SHA로 macos-release.yml을 tag=v0.16.0, publish=publish로 실행한다. GitHub macOS arm64 러너에서 고정 인증서 앱과 Sparkle 서명 DMG/appcast를 만들고 재다운로드 검증 후 공개한다. 서명 비밀값은 기존 GitHub secret 격리 절차로만 사용한다.

배포 전에 원본 SHA와 manifest의 SHA·앱 버전·DMG checksum·고정 DR을 확인한다. 이전 v0.15.0 릴리즈 자산을 보존한다. 문제가 있으면 v0.16.0을 최신 피드에서 제외하고 v0.15.0을 최신으로 복구하여 추가 자동 배포를 멈춘다. 이미 설치된 사용자에게 자동 다운그레이드는 하지 않는다. 필요하면 보존된 v0.15.0 DMG를 수동 재설치한다. 이 변경은 DB migration을 추가하지 않는다.
