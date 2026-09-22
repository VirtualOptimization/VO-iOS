# V-O iOS 개발 환경 세팅

클론한 뒤 이 문서대로 따라 하면 실기기에서 앱이 뜹니다.

## 준비물

| 항목 | 요구사항 |
|---|---|
| Mac | Xcode 16 이상 |
| 기기 | **LiDAR 탑재 iPhone 필수** (iPhone 12 Pro 이상 / iPad Pro) |
| 계정 | Apple 개발자 계정 (무료 계정도 실기기 설치는 가능) |
| iOS | 17.0 이상 |

> 시뮬레이터에서는 스캔이 동작하지 않습니다. RoomPlan이 실제 LiDAR 센서를 요구해서,
> 스캔 이후 화면(내 방 조회, 편집, AI 상담)만 시뮬레이터로 확인할 수 있습니다.

## 1. 설정 파일 만들기 (필수)

`Configuration/Secrets.xcconfig`는 gitignore되어 있는데 **앱 타겟의 base configuration**으로
걸려 있습니다. 이 파일이 없으면 빌드 설정을 못 읽어서 번들 ID와 서명이 깨집니다.

```bash
cp Configuration/Secrets.xcconfig.example Configuration/Secrets.xcconfig
```

복사만 하면 됩니다. 안에 든 `SERVER_BASE_URL`은 현재 코드에서 참조하지 않으니 값을 바꿀
필요는 없습니다. 서버 주소는 아래 3번을 보세요.

## 2. 서명 설정

Xcode에서 `RoomPlanCatalogGenerator.xcodeproj`를 열고
**RoomPlanExporter 타겟 → Signing & Capabilities**에서 본인 Team을 선택합니다.
번들 ID가 충돌하면 뒤에 이니셜을 붙여 바꾸면 됩니다.

## 3. 서버 주소

[RoomPlanExporter/Services/APIConfig.swift](RoomPlanExporter/Services/APIConfig.swift)에
하드코딩되어 있습니다.

```swift
static let baseURL = "http://3.27.213.100/api"
```

EC2 인스턴스를 다시 띄우면 IP가 바뀌므로 **이 한 줄만** 고치면 됩니다.
서버 레포는 `VirtualOptimization/VO-server`입니다.

## 4. 빌드 & 실행

Xcode에서 기기를 연결하고 실행하거나, 터미널에서 빌드만 확인하려면:

```bash
xcodebuild -scheme RoomPlanExporter -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

## 프로젝트 구조

```
RoomPlanExporter/
├─ Services/          서버 통신 + 계산 로직
│   ├─ APIConfig.swift            서버 주소 (여기만 고치면 됨)
│   ├─ RoomOptimizerService.swift 방/버전 관련 API 전부
│   ├─ AuthService.swift          로그인·회원가입
│   ├─ AssistantService.swift     AI 상담 (서버 프록시 호출)
│   └─ RoomFitCalculator.swift    상담용 면적·배치 계산 (AI가 아니라 여기서 계산)
├─ ViewModels/
│   ├─ ScanViewModel.swift        화면 단계(phase) 관리 — 앱 흐름의 중심
│   ├─ ScanViewModel+RoomScan.swift   스캔·업로드·최적화
│   ├─ ScanViewModel+Inquiry.swift    내 방 조회·편집 저장·삭제
│   └─ AssistantViewModel.swift   Claude tool-use 루프
├─ Views/
│   ├─ Scan/          스캔, 결과, 내 방 조회, 3D 뷰어
│   ├─ Assistant/     AI 상담 패널
│   ├─ Auth/          로그인·회원가입
│   └─ Shared/        공용 버튼·카드 스타일
├─ Controllers/       RoomPlan 캡처 컨트롤러
├─ Models/            RoomPlan 카탈로그 모델
└─ RoomPlanCatalog.bundle/   Apple 제공 3D 가구 모델
```

## 앱 흐름

화면 전환은 전부 `ScanViewModel.phase`로 관리합니다. 새 화면을 붙일 땐 phase를 추가하고
[ContentView.swift](RoomPlanExporter/Views/ContentView.swift)의 switch에 케이스를 넣으면 됩니다.

```
main → guide → countdown → scanning → result → uploading
     → uploadComplete → (저장) → inquiryResult
                                    ├─ 최적화 → processing → inquiryResult
                                    ├─ 가구 편집 → 이름 입력 → 새 버전 저장
                                    └─ AI 상담
```

**저장과 최적화는 분리되어 있습니다.** 스캔 후 저장하면 세션이 끝나고, 최적화·편집·상담은
모두 "내 방 조회" 화면에서 실행합니다.

## 서버 API 흐름

전부 `RoomOptimizerService`에 모여 있습니다. 기본 경로는 `{baseURL}/rooms`.

| 메서드 | 경로 | 설명 |
|---|---|---|
| POST | `/rooms/start` | 방 생성 + S3 업로드 URL 발급 |
| PUT | (S3 presigned URL) | usdz / json 직접 업로드 |
| POST | `/rooms/{id}/complete` | 업로드 확정 → ORIGINAL 버전 생성 |
| POST | `/rooms/{id}/optimize` | 최적화 시작 (백그라운드, 30초 내외) |
| GET | `/rooms/{id}` | 방 상태 조회 (최적화 진행 폴링) |
| PATCH | `/rooms/{id}` | 방 이름 변경 |
| DELETE | `/rooms/{id}` | 방 삭제 (버전 전부 함께 삭제) |
| GET | `/rooms` | 내 방 목록 |
| GET | `/rooms/{id}/versions` | 버전 목록 |
| GET | `/rooms/{id}/versions/{vid}` | 버전 상세 (3D URL + 가구 좌표) |
| POST | `/rooms/{id}/versions` | 편집본 저장 (`ios_objects` 전송) |
| PATCH | `/rooms/{id}/versions/{vid}` | 버전 이름 변경 |
| DELETE | `/rooms/{id}/versions/{vid}` | 버전 삭제 |
| POST | `/assistant/messages` | AI 상담 (서버가 Claude API 프록시) |

### 좌표계 주의

서버는 같은 배치를 두 좌표계로 저장합니다.

- `layout_json_url` — **RoomPlan 좌표계**. 스캐너 원점 기준이라 바닥이 y ≈ -1.0처럼 음수. iOS가 씁니다.
- `unity_layout_json_url` — **Unity 좌표계**. 바닥이 y = 0으로 정규화됨. VR이 씁니다.

편집본을 저장할 때 iOS는 `ios_objects`에, Unity는 `objects`에 담아 보냅니다.
서버는 어느 필드가 왔는지로 저장 출처(`editor: "IOS" | "UNITY"`)를 기록하고, 앱은 그 값으로
버전 목록에 **앱 / VR** 뱃지를 표시합니다.

## 자주 겪는 문제

**빌드가 "Build input file cannot be found"로 실패**
이 프로젝트는 파일이 `project.pbxproj`에 명시적으로 등록되어 있습니다(Resources 폴더만 예외).
Xcode 밖에서 파일을 지우거나 추가했다면 pbxproj도 함께 손봐야 합니다. Xcode에서 추가/삭제하는 걸 권장합니다.

**API 요청이 502 Bad Gateway**
서버 배포 중일 가능성이 높습니다. `dev` 브랜치에 푸시하면 GitHub Actions가 EC2에서 서비스를
재시작하는데, 그 몇 초 동안 502가 납니다. 잠시 후 재시도하세요.

**AI 상담이 503**
서버에 `ANTHROPIC_API_KEY`가 설정되지 않은 상태입니다. 앱 문제가 아니니 서버 담당자에게 문의하세요.
**키는 앱에 넣지 않습니다.**

**시뮬레이터에서 스캔 버튼이 안 먹음**
정상입니다. LiDAR가 필요합니다.

## 커밋 규칙

- 작업은 `feat/...` 브랜치에서 하고 `main`으로 PR
- **`Configuration/Secrets.xcconfig`는 절대 커밋하지 마세요** (gitignore에 있지만 `-f`로 강제 추가 금지)
