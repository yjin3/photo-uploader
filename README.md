# Photo Uploader

Tailscale로 연결된 Android → PC 사진 전송 앱. 로컬 Flutter/Android Studio 설치 불필요.

## APK 만들기

1. 이 폴더의 모든 파일(`android/gradle/wrapper/gradle-wrapper.jar` 포함)을 GitHub 저장소에 업로드합니다.
2. **Actions → Build Android APK → Run workflow**를 실행합니다.
3. 완료된 실행의 **photo-uploader-apk** Artifact를 다운로드하고 압축을 풉니다.
4. `app-arm64-v8a-release.apk`를 Android 스마트폰에 설치합니다.

Java 17과 실행 시점의 최신 stable Flutter를 사용합니다. Android 최소 API는 24 이상이며 Flutter 기본값이 더 높으면 따릅니다. APK는 개인 설치용 debug 키로 서명합니다. CI에서 의존성을 해석하며 `pubspec.lock` 생성 후 저장소에 커밋하면 Dart 의존성 버전을 고정할 수 있습니다.

빌드 시간을 줄이기 위해 업로드 대상인 ARM64 APK만 생성합니다. Flutter/Pub 및 Gradle 캐시를 재사용하고 Gradle 작업 캐시와 병렬 실행을 활성화했습니다. 첫 실행이나 SDK/의존성 변경 시에는 다운로드와 초기 컴파일이 필요합니다. 같은 브랜치에 연속으로 push하면 이전 실행을 취소하고 최신 실행만 진행합니다. 전체 ABI가 필요하면 워크플로의 `--target-platform android-arm64` 옵션을 제거하세요.

## PC 서버 실행

Python 3.10 이상:

```powershell
python -m venv .venv
.\.venv\Scripts\python -m pip install -r pc_server/requirements.txt
.\.venv\Scripts\python pc_server/server.py
```

PC와 스마트폰 모두 Tailscale에 로그인하고 서로 연결되어 있어야 합니다. PC의 Tailscale IPv4 주소(`tailscale ip -4`) 또는 MagicDNS 이름을 앱 설정에 입력합니다. 예: `http://100.101.102.103:8000`. 기본 표시 주소 `100.x.y.z`는 예시이므로 실제 주소로 변경해야 합니다.

서버는 `0.0.0.0:8000`에서 수신합니다. PC 방화벽과 Tailscale 접근 규칙에서 스마트폰 → PC TCP 8000을 허용하세요. 브라우저에서 `http://PC주소:8000/health`로 연결을 확인할 수 있습니다. 공유기 포트 포워딩은 필요하지 않습니다. 서버 자체 인증은 없으므로 방화벽에서 Tailscale 대역/필요한 기기로 접근을 제한하세요.

사진은 `pc_server/uploads/20261106_153000_태그/`에 저장됩니다. 태그가 없으면 시간만 사용하고, 같은 초의 요청은 `_1` 등을 붙입니다. 경로 문자를 정리하며 같은 이름의 파일을 덮어쓰지 않습니다. 모든 파일 저장을 마친 뒤 HTTP 200을 반환합니다. 응답이 유실되어 재전송하면 별도 디렉터리가 생길 수 있습니다.

사진 파일명은 원본 이름과 확장자를 유지합니다. 원본 이름이 없거나 GUID이면 `20261106_153000_001.jpg`처럼 수신 일시와 순번을 사용합니다. 확장자가 없으면 파일 헤더 또는 이미지 MIME 유형으로 JPEG/PNG/HEIC 등의 실제 형식을 확인해 확장자를 붙입니다. 확장자만 보정하며 이미지 데이터는 변환하지 않습니다. 서버 수정은 재시작 후 적용되므로 기존 APK에서 보내는 GUID 파일명도 보정됩니다.

## 원본 삭제

삭제 체크박스 기본값은 true입니다. Android 시스템 파일 선택기의 **이미지** 또는 **사진**에서 여러 사진을 선택하세요. 원본 URI를 보존하기 위해 Android에서는 `image_picker.pickMultiImage()` 대신 네이티브 `ACTION_OPEN_DOCUMENT`를 사용합니다. 업로드용 복사본의 경로와 원본 파일명을 별도로 보관하며 전송 시 원본 파일명을 사용합니다.

PC가 모든 파일을 저장하고 HTTP 200을 반환한 뒤에만 원본 삭제를 요청합니다. Android 11 이상에서 Android가 원본 MediaStore URI를 제공하는 사진은 `MediaStore.createDeleteRequest()`의 시스템 확인 창에서 승인하면 실제 원본을 영구 삭제합니다. 그 외 문서 제공자와 Android 10 이하에서는 확인 창을 거쳐 선택한 원본 문서에 `DocumentsContract.deleteDocument()`를 호출하며, Android 10의 추가 시스템 승인도 처리합니다. 삭제 완료 뒤 업로드용 복사본과 선택 목록을 정리하고 완료 메시지를 표시합니다. 앱은 열린 상태로 유지되어 다음 사진을 선택하고 전송할 수 있습니다. 삭제 체크를 해제한 경우에도 전송 완료 후 선택 목록을 비웁니다. 파일명이나 용량으로 원본을 추측하지 않습니다.

삭제 취소 또는 실패 시 목록을 유지하고 오류를 표시합니다. **전송 완료 처리 계속**을 누르면 재전송 없이 남은 처리를 재시도합니다. 선택한 원본 URI와 전송 완료 상태, 개별 삭제 완료 상태를 로컬에 저장하므로 앱이 재시작되어도 이어서 처리합니다. 삭제를 지원하지 않는 제공자는 성공으로 처리하지 않습니다. 기기의 로컬 사진을 선택하세요. 클라우드 동기화 서비스의 원본/백업 보존 정책은 해당 서비스의 설정을 따릅니다.

참고: [Flutter Android 배포](https://docs.flutter.dev/deployment/android), [Android MediaStore 삭제](https://developer.android.com/training/data-storage/shared/media#remove-item), [DocumentsContract](https://developer.android.com/reference/android/provider/DocumentsContract).
