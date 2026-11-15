#!/usr/bin/env bash
# =============================================================================
#  Сборка VCContacts в Docker-контейнере и вынос артефактов в ./apk
#
#  Использование:
#    ./build.sh                 # samsung + huawei (по умолчанию)
#    ./build.sh samsung         # только Samsung S22+
#    ./build.sh huawei          # только Huawei
#    ./build.sh --test          # только анализ и тесты, без APK
#
#  Результат: apk/app-arm64-v8a-samsung-release.apk и
#  apk/app-arm64-v8a-huawei-release.apk (AAB не собирается; см. Dockerfile).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_TAG="vccontacts-builder:latest"
BUILD_DIR="$SCRIPT_DIR/apk"
TARGET="artifacts"
FLAVORS="${FLAVORS:-samsung huawei}"

for arg in "$@"; do
  case "$arg" in
    --test)
      TARGET="test"
      ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    samsung|huawei|all)
      if [ "$arg" = "all" ]; then
        FLAVORS="samsung huawei"
      else
        FLAVORS="$arg"
      fi
      ;;
    *)
      echo "Неизвестный аргумент: $arg (см. --help)" >&2
      exit 1
      ;;
  esac
done

echo "==> [1/3] Сборка Docker-образа (стадии: toolchain -> code -> test -> ${TARGET})"
echo "    Флаворы: ${FLAVORS}"
docker build \
  --target "${TARGET}" \
  --build-arg FLAVORS="${FLAVORS}" \
  -t "${IMAGE_TAG}" \
  -f Dockerfile .

if [ "${TARGET}" = "test" ]; then
  echo "==> Анализ и тесты прошли успешно."
  exit 0
fi

echo "==> [2/3] Извлечение артефактов из контейнера в ${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
CID="$(docker create "${IMAGE_TAG}")"
cleanup() { docker rm -f "${CID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# docker cp умеет точку как источник-каталог
docker cp "${CID}:/out/." "${BUILD_DIR}/"
cleanup
trap - EXIT

echo "==> [3/3] Готово. Содержимое ${BUILD_DIR}:"
ls -lah "${BUILD_DIR}"

echo
echo "Установка на устройство:"
echo "  adb install -r apk/app-arm64-v8a-samsung-release.apk   # Samsung S22+"
echo "  adb install -r apk/app-arm64-v8a-huawei-release.apk    # Huawei"
