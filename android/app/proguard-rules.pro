# google_mlkit_text_recognition (v0.13) в своей Java-обёртке ссылается на
# опциональные распознаватели korean/chinese/japanese/devanagari, артефакты
# которых плагин не подключает (в проекте только latin). Классы не
# загружаются в рантайме (скрипт всегда latin) — R8-предупреждения подавляем.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
