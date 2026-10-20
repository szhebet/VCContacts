# =============================================================================
#  VCContacts — многостадийная сборка приложения (Linux, x86_64 хост)
#
#  Стадия 1 (toolchain): установка ПО — JDK 17, Android SDK, Flutter, Gradle.
#  Стадия 2 (code):      зависимости проекта (pub get) + исходный код.
#  Стадия 3 (test):      статический анализ и юнит-тесты.
#  Стадия 4 (artifacts): сборка релизных APK/AAB для Samsung и Huawei.
#
#  Использование: ./build.sh  (или см. README)
# =============================================================================

# -----------------------------------------------------------------------------
# СТАДИЯ 1. Установка ПО и инструментов
# -----------------------------------------------------------------------------
FROM ubuntu:22.04 AS toolchain

ENV DEBIAN_FRONTEND=noninteractive

# Базовые системные пакеты + JDK 17 (требование AGP 8.x)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        unzip \
        xz-utils \
        zip \
        openjdk-17-jdk-headless \
    && rm -rf /var/lib/apt/lists/*

# --- Android SDK (command-line tools, platform 34, build-tools 34) ---
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=${ANDROID_HOME}
ENV PATH=${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools \
    && curl -fsSLo /tmp/cmdline-tools.zip \
         https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
    && unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_HOME}/cmdline-tools \
    && mv ${ANDROID_HOME}/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest \
    && rm /tmp/cmdline-tools.zip

# Лицензии принимаем заранее — иначе flutter build остановится на промпте
RUN yes | sdkmanager --licenses > /dev/null \
    && sdkmanager --install \
         "platform-tools" \
         "platforms;android-34" \
         "build-tools;34.0.0" \
    && rm -rf ${ANDROID_HOME}/.temp

# --- Flutter SDK (stable, версия фиксируется для воспроизводимости) ---
ENV FLUTTER_HOME=/opt/flutter
ARG FLUTTER_VERSION=3.24.5

RUN curl -fsSLo /tmp/flutter.tar.xz \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && tar -xf /tmp/flutter.tar.xz -C /opt \
    && rm /tmp/flutter.tar.xz \
    && git config --global --add safe.directory ${FLUTTER_HOME}

ENV PATH=${PATH}:${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin

# Отключаем аналитику и заранее готовим Android-артефакты Flutter
RUN flutter config --no-analytics \
    && dart --disable-analytics \
    && flutter precache --android \
    && flutter --version

# --- Gradle (нужен, чтобы сгенерировать gradle-wrapper.jar в контейнере) ---
ARG GRADLE_VERSION=8.7
ENV GRADLE_HOME=/opt/gradle-${GRADLE_VERSION}
ENV PATH=${PATH}:${GRADLE_HOME}/bin

RUN curl -fsSLo /tmp/gradle.zip \
        "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
    && unzip -q /tmp/gradle.zip -d /opt \
    && rm /tmp/gradle.zip \
    && gradle --version

# --- Зеркало Maven Central для сети сборки ---
# В проксируемой сети сборки недоступны repo.maven.apache.org и
# plugins.gradle.org; Maven Central доступен как repo1.maven.org.
# Init-скрипт применяется ко ВСЕМ Gradle-сборкам, включая встроенную
# flutter_tools/gradle, чьи URL мы не контролируем.
RUN mkdir -p /root/.gradle/init.d \
    && cat > /root/.gradle/init.d/00-maven-mirror.gradle <<'EOF'
def mirror = 'https://repo1.maven.org/maven2'

def isBlocked = { r ->
    try {
        def s = r.hasProperty('url') ? (r.url?.toString() ?: '') : ''
        return s.contains('repo.maven.apache.org') || s.contains('plugins.gradle.org')
    } catch (Exception ignored) {
        return false
    }
}

def fix = { handler ->
    try {
        def victims = []
        def hasMirror = false
        handler.each { r ->
            if (isBlocked(r)) victims << r
            try {
                def s = r.hasProperty('url') ? (r.url?.toString() ?: '') : ''
                if (s.contains('repo1.maven.org')) hasMirror = true
            } catch (Exception ignored) {}
        }
        victims.each { handler.remove(it) }
        if (!hasMirror) handler.maven { it.url = mirror }
    } catch (Exception ignored) {}
}

gradle.beforeSettings { s -> fix(s.pluginManagement.repositories) }
settingsEvaluated { s ->
    fix(s.pluginManagement.repositories)
    try { fix(s.dependencyResolutionManagement.repositories) } catch (Exception ignored) {}
}
allprojects { p ->
    fix(p.repositories)
    fix(p.buildscript.repositories)
}
EOF

# -----------------------------------------------------------------------------
# СТАДИЯ 2. Зависимости проекта и исходный код
# -----------------------------------------------------------------------------
FROM toolchain AS code

WORKDIR /workspace

# Сначала только манифест пакетов — слой с pub-кэшем переживает правки кода
COPY pubspec.yaml ./
RUN flutter pub get

# Затем весь исходный код
COPY . .

# local.properties flutter tool генерирует на dev-машине автоматически;
# в контейнере создаём вручную, иначе gradle-wrapper/analyze упадёт
# на чтении flutter.sdk (файл также перезапишет flutter build).
RUN printf 'flutter.sdk=/opt/flutter\n' > android/local.properties

# Android Gradle Plugin вызывает gradlew; в git только wrapper properties,
# поэтому генерируем jar (если его по какой-то причине нет в репозитории)
ARG GRADLE_VERSION=8.7
RUN if [ ! -f android/gradle/wrapper/gradle-wrapper.jar ]; then \
        (cd android && gradle wrapper --gradle-version ${GRADLE_VERSION} --offline || gradle wrapper --gradle-version ${GRADLE_VERSION}); \
    fi \
    && ls -la android/gradle/wrapper/

# -----------------------------------------------------------------------------
# СТАДИЯ 3. Анализ и тесты (билд артефактов падает, если тесты красные)
# -----------------------------------------------------------------------------
FROM code AS test

RUN flutter analyze --no-fatal-infos \
    && flutter test --reporter expanded

# -----------------------------------------------------------------------------
# СТАДИЯ 4. Сборка релизных артефактов
# -----------------------------------------------------------------------------
FROM test AS artifacts

# Какие флаворы собирать: samsung (S22 и новее) и/или huawei (без GMS)
ARG FLAVORS="samsung huawei"
# Целевые ABI: arm64-v8a (S22+/Huawei)
ARG TARGET_PLATFORM="android-arm64"
# Собирать ли также App Bundle (.aab) для магазинов
# (по умолчанию нет: нужны только APK для ручной установки;
#  включить: docker build --build-arg BUILD_AAB=true ...)
ARG BUILD_AAB=false

RUN mkdir -p /out \
    && for flavor in ${FLAVORS}; do \
           echo "======== Сборка флавора: ${flavor} ========" \
           && flutter build apk --release --split-per-abi \
                 --flavor "${flavor}" --target-platform "${TARGET_PLATFORM}" \
           && cp build/app/outputs/flutter-apk/app-*"${flavor}"-*.apk /out/ \
           && if [ "${BUILD_AAB}" = "true" ]; then \
                  flutter build appbundle --release --flavor "${flavor}" \
                  && cp build/app/outputs/bundle/"${flavor}"Release/app-"${flavor}"-release.aab /out/ ; \
              fi ; \
       done \
    && echo "======== Готово ========" \
    && ls -lah /out

# Для локальной проверки: docker run --rm <image>
CMD ["ls", "-lah", "/out"]
