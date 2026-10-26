# 회의 로컬 모델과 라이선스

확인일: 2026-10-26. WorkLog는 공개 **Argmax Open-Source SDK 1.1.1**의 WhisperKit과 SpeakerKit만 연결한다. Pro SDK, API 키, 클라우드 음성 추론은 사용하지 않는다. Swift 패키지는 macOS 앱에만 의존하며 WorkLogCore/Linux에는 연결하지 않는다.

## 선택과 공개 API

- SDK: [`argmaxinc/argmax-oss-swift` v1.1.1](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.1), commit `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`. `Package.swift` exact 버전과 `Package.resolved` revision으로 고정한다.
- 실시간 화면: WhisperKit의 다국어 large-v3-turbo Core ML을 제한된 rolling window에 반복 실행한다. 이는 앱이 만든 미리보기 파이프라인이며, SDK가 제공하는 완성형 스트리밍 화자 인식이라고 표시하지 않는다. 한국어를 기본 언어로 지정하며 엔진은 언어 지정/자동 감지도 지원한다.
- 종료 후 최종 전사: 원래 large-v3 Core ML을 30초 이하 구간에 순차 실행한다. live 엔진을 내려 메모리를 비운 뒤 final 엔진을 사용한다. 모델 파일 전체를 메모리에 읽지 않고 Core ML에 로컬 경로를 넘긴다.
- 화자 구분: **SpeakerKit OSS Pyannote community-1**을 선택했다. 공개 `diarize(audioArray:options:progressCallback:)`와 `speakerCentroidEmbeddings`로 최대 120초 모노 PCM 구간의 화자 구간·특징값을 반환한다. 각 호출의 화자 번호는 독립적이다. 구간 간 특징 비교 결과는 잠정 연결이며 실명이나 동일인 확인으로 취급하지 않는다. 겹침 발화를 한 명으로 강제하지 않는다.
- [SpeakerKit은 v0.17.0부터 공개](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v0.17.0)되었다. [OSS README](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/README.md)는 Pyannote 기반 API와 별도로 Pro의 실시간 통합 화자 인식·추가 모델을 구분한다. 공개 API가 요구 범위를 충족해 FluidAudio를 추가 의존성으로 넣지 않았다. [FluidAudio의 오프라인 로컬 모델 로딩](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/SpeakerDiarization.md)은 대안으로 조사했다.

## 고정 모델 목록

용량은 실제 다운로드 대상의 합계이며 GB는 십진 단위다. Core ML의 기기별 캐시·메모리와 다운로드 중 임시 공간은 별도다. SDK에서 더 이상 사용하지 않는 `TextDecoderContextPrefill`은 내려받지 않는다.

| 역할 | 모델 저장소와 경로 | revision | 대상 용량 |
|---|---|---|---:|
| 실시간 | `argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo` + turbo 토크나이저 | `0f63a7800b00dd0226abd051b906c246e1907482` | 1,629,163,735 bytes |
| 최종 | `argmaxinc/whisperkit-coreml/openai_whisper-large-v3` + large-v3 토크나이저 | 동일 | 3,093,084,631 bytes |
| 화자 | `argmaxinc/speakerkit-coreml`: segmenter/embedder `pyannote-v3/W8A16`, clusterer `pyannote-v4/W32A32` | `556fc52a13327837688f02289457cded017802e9` | 11,243,231 bytes |

토크나이저는 각 저장소의 `config.json`, `tokenizer.json`, `tokenizer_config.json`을 별도 `tokenizer/` 폴더에 준비한다.

- `openai/whisper-large-v3-turbo`: `41f01f3fe87f28c78e2fbf8b568835947dd65ed9`
- `openai/whisper-large-v3`: `06f233fe06e710322aca913c1bc4249a0d71fce1`

원본 metadata는 Hugging Face의 고정 revision tree API로 확인했다. 앱의 `MeetingModelRegistry.swift`에 67개 파일의 repository/revision/원격 경로/로컬 경로/정확한 크기/예상 digest를 고정한다. LFS 파일은 공급자가 공개한 SHA256, 일반 Git 파일은 `blob <size>\0` 헤더를 포함한 Git SHA1으로 확인한다. 설치 시에는 **모든 파일의 SHA256도 추가 계산**하여 `installation.json`에 SDK 버전·원출처·라이선스·설치 시각과 함께 기록한다. 실행 시의 모델 로딩은 이 목록과 digest를 다시 검사한다. mutable `main`, 자동 추천 모델, 외부 계정의 Hugging Face 캐시에는 의존하지 않는다.

## 준비·취소·오프라인 처리

앱 생성, 상태 조회, 녹음, 추론은 다운로드를 시작하지 않는다. 사용자가 각 **모델 준비**를 실행할 때만 고정 공개 HTTPS URL에서 모델·토크나이저 파일을 받는다. 다운로드 요청에 음성·전사문·메모·로그인 토큰을 넣지 않으며 URLSession의 자격증명·쿠키 저장소도 사용하지 않는다.

파일은 임시 디렉터리에 내려받아 크기·digest를 검증한다. 모든 파일이 완료돼야 receipt를 쓰고 준비 완료로 바꾼다. 진행률을 표시하고 사용자가 취소할 수 있다. 실패·취소 후 다시 준비하면 이미 검증된 개별 파일을 재사용한다. 중단된 한 파일의 byte-range 재개는 지원하지 않고 그 파일을 다시 받는다. 자동 재시도나 자동 업데이트는 하지 않는다.

WhisperKit 1.1.1의 [기본 토크나이저 로더](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/WhisperKit/Utilities/ModelUtilities.swift)는 로컬 파일 파싱 실패 후 네트워크로 넘어간다. 따라서 `download: false`만 사용하지 않는다. WorkLog는 `AutoTokenizerWrapper.from(modelFolder:)`의 로컬 전용 factory로 읽은 토크나이저를 직접 주입하고, `loadTokenizerIfNeeded`를 재정의해 누락·손상 시 실패하게 한다. SpeakerKit도 `modelFolder`, `download: false`, 빈 `modelToken`을 명시한다. 모델이 없거나 손상돼도 추론은 다운로드로 복구하지 않는다.

전사 입력은 16kHz mono Float PCM 최대 30초, 화자 구분은 최대 120초다. 길이가 긴 회의의 파일 읽기·구간 순서·화자 연결은 상위 조정자가 담당한다. Swift task 취소와 모델 unload generation을 검사해 취소 뒤 결과를 반영하지 않는다. Core ML의 이미 실행 중인 단일 연산은 즉시 중단되지 않을 수 있다.

## 코드·모델 고지

라이선스는 코드와 모델을 구분한다. 아래 원문 링크와 저작권 고지를 앱 배포물에 함께 보존한다. 모델 파일을 WorkLog가 재학습·재양자화하지 않으며, Argmax가 제공하는 Core ML 변환·양자화 결과를 그대로 사용한다.

| 대상 | 공개 고지와 원문 |
|---|---|
| Argmax SDK 코드 | MIT, Copyright (c) 2024 argmax, inc. [LICENSE](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/LICENSE) |
| SDK에 포함된 swift-transformers/tokenizer 코드 | Apache-2.0, Copyright 2022 Hugging Face SAS. Argmax 수정 내역을 포함한 [NOTICES](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/NOTICES) |
| Whisper Core ML 모델 | Argmax 저장소 모델카드 MIT: [고정 revision 모델카드](https://huggingface.co/argmaxinc/whisperkit-coreml/blob/0f63a7800b00dd0226abd051b906c246e1907482/README.md). 원본 OpenAI Whisper 및 Argmax 변환 |
| turbo 토크나이저 | upstream 모델카드 MIT: [고정 revision](https://huggingface.co/openai/whisper-large-v3-turbo/blob/41f01f3fe87f28c78e2fbf8b568835947dd65ed9/README.md) |
| large-v3 토크나이저 | upstream 모델카드 Apache-2.0: [고정 revision](https://huggingface.co/openai/whisper-large-v3/blob/06f233fe06e710322aca913c1bc4249a0d71fce1/README.md). Whisper 코드의 MIT 표기와 구분 |
| SpeakerKit Core ML 묶음 | Argmax 모델카드 CC-BY-4.0: [고정 revision](https://huggingface.co/argmaxinc/speakerkit-coreml/blob/556fc52a13327837688f02289457cded017802e9/README.md), [라이선스 전문](https://creativecommons.org/licenses/by/4.0/legalcode.en) |
| SpeakerKit segmentation 원출처 | pyannote/segmentation-3.0, MIT, Copyright (c) 2023 CNRS. [원문](https://huggingface.co/pyannote/segmentation-3.0/blob/main/LICENSE) |
| SpeakerKit embedding 원출처 | WeSpeaker / WeNet. pretrained 모델은 데이터셋 라이선스를 따르며 VoxCeleb은 CC-BY-4.0. [원문](https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md#model-license) |
| SpeakerKit PLDA 원출처 | VBx, Brno University of Technology, Apache-2.0. [원문](https://github.com/BUTSpeechFIT/VBx#license) |

SpeakerKit 원출처 링크는 Argmax의 고정 revision 내 `speaker_segmenter/pyannote-v3/README.txt`, `speaker_embedder/pyannote-v3/README.txt`, `speaker_clusterer/pyannote-v4/README.txt`에서 확인했다. bundle에는 SDK `LICENSE`와 `NOTICES`, 이 모델 고지를 포함한다. CC-BY 고지: **Pyannote / CNRS, WeSpeaker / WeNet, VBx / Brno University of Technology, Core ML conversion and quantization by Argmax, Inc.** 출처는 위 표이며 변경 없음(`unchanged by WorkLog`)을 명시한다. 원출처나 작성자가 WorkLog를 보증한다는 의미는 아니다.

## 검증 범위

`scripts/maclab/run-meeting-model-check.sh`는 네트워크를 차단하고 작은 가짜 파일만 사용한다. 미설치 조회/추론 검증의 무통신, 부분 준비 상태, 재시도 시 검증 파일 재사용, SHA256/Git blob 검증, provenance receipt, 동일 크기 변조 거부, 취소 후 명시적 재시도, 고정 registry 형식을 확인한다.

`scripts/maclab/run-meeting-tokenizer-check.sh`는 미리 빌드한 실제 SDK 1.1.1 오브젝트를 연결하여 네트워크 차단 상태에서 3개 경계를 확인한다: 로컬 토크나이저 누락, 손상된 JSON, WorkLog의 lazy tokenizer loader 재정의. 모두 다운로드 없이 오류를 반환하는지 검사하며 모델 가중치는 읽지 않는다.

이 구현 작업에서는 실제 모델을 다운로드하거나 실제 회의 음성을 읽지 않았다. 실제 모델 로딩 성공·한국어 정확도·화자 분리 품질·M1 Max 지연시간·peak memory는 사용자의 명시적 모델 준비 후 검증해야 한다. SDK 타입 검사와 가짜 파일 테스트를 실제 모델 추론 검증으로 간주하지 않는다. 미리보기는 기본 2초 간격으로 갱신을 시도하며, 실제 지연은 하드웨어·발화·Core ML 초기 준비에 영향을 받는다. 2초 완료를 보장하지 않는다.
