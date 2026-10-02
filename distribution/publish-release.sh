#!/bin/bash
# 테스트·DMG 검증을 통과한 뒤 job 범위 GH_TOKEN으로만 호출된다.
# draft 생성 → 업로드 → 바이트 readback 비교 → asset 개수 확인 → 선택적 promote.
# 기존 tag/release(초안 포함)는 절대 덮어쓰지 않는다. --clobber 금지.
set -euo pipefail
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}" "${RELEASE_TAG:?}"
[[ "$GITHUB_REPOSITORY" == RunaticMoon/worktrail ]] || { printf '%s\n' 'Unexpected repository' >&2; exit 1; }
[[ ${PROMOTE:-false} == true || ${PROMOTE:-false} == false ]] || exit 1

python3 distribution/release.py version "$RELEASE_TAG" VERSION
python3 distribution/release.py verify "$RELEASE_TAG" release
python3 distribution/release.py verify-appcast "$RELEASE_TAG" release

# 같은 이름의 tag ref나 release(초안 포함)가 이미 있으면 운영자 복구가 필요하므로 실패한다.
refs=$(gh api "repos/$GITHUB_REPOSITORY/git/matching-refs/tags/$RELEASE_TAG")
REFS="$refs" python3 -c 'import json,os; assert not any(r["ref"] == "refs/tags/"+os.environ["RELEASE_TAG"] for r in json.loads(os.environ["REFS"])), "Tag already exists; operator recovery required"'
gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases?per_page=100" | python3 -c 'import json,os,sys; assert not any(r["tag_name"] == os.environ["RELEASE_TAG"] for page in json.load(sys.stdin) for r in page), "Release/draft already exists: operator recovery required"'

gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" --draft \
  --title "WorkLog $RELEASE_TAG" \
  --notes "WorkLog $RELEASE_TAG, Apple Silicon(arm64) ad-hoc 서명 빌드 from $GITHUB_SHA. Developer ID 서명·Apple 공증이 없으므로 첫 실행 시 macOS 보안 설정에서 사용자 승인이 필요할 수 있습니다. DMG SHA-256은 release-manifest.json에 있습니다. 앱 안 업데이트 확인과 자동 다운로드를 지원하며 업데이트 DMG와 appcast는 Ed25519로 서명합니다. 기존 1.x 앱은 이 버전을 한 번 직접 설치하세요."

assets=(release/*.dmg release/release-manifest.json release/appcast.xml)
gh release upload "$RELEASE_TAG" "${assets[@]}" --repo "$GITHUB_REPOSITORY"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --dir "$work"
# 원격 manifest만 믿지 않고 업로드한 바이트를 그대로 다시 받아 비교한다.
for asset in "${assets[@]}"; do cmp "$asset" "$work/$(basename "$asset")"; done
python3 distribution/release.py verify "$RELEASE_TAG" "$work"
python3 distribution/release.py verify-appcast "$RELEASE_TAG" "$work"

info=$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json isDraft,assets)
INFO="$info" python3 -c 'import json,os; r=json.loads(os.environ["INFO"]); assert r["isDraft"] and len(r["assets"])==3'
if [[ ${PROMOTE:-false} == true ]]; then
  gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --draft=false --prerelease=false --latest
  [[ $(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft) == false ]]
fi
