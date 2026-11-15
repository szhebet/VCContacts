package com.vccontacts.app

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaPlayer
import android.media.MediaRecorder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Нативный мост для голосовых заметок.
 *
 * Запись: AudioRecord (PCM 16 кГц, моно) сразу в WAV — этот формат читает
 * whisper.cpp. Воспроизведение: MediaPlayer. Файлы лежат в приватном
 * каталоге приложения, путь создаёт Dart-сторона.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "vccontacts/voice_notes"

    private var player: MediaPlayer? = null
    private var playResult: MethodChannel.Result? = null

    private var audioRecord: AudioRecord? = null
    private var recordThread: Thread? = null
    private var recordFile: RandomAccessFile? = null
    private var recordPath: String? = null

    @Volatile
    private var recording = false
    private var recordSamples = 0L

    private val sampleRate = 16000

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return FlutterEngineCache.getInstance().get(VcApplication.ENGINE_ID)
            ?: super.provideFlutterEngine(context)!!
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRecording" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path is empty", null)
                        } else {
                            startRecording(path, result)
                        }
                    }
                    "stopRecording" -> stopRecording(result)
                    "play" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path is empty", null)
                        } else {
                            play(path, result)
                        }
                    }
                    "stopPlayback" -> {
                        stopPlayback()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @SuppressLint("MissingPermission")
    private fun startRecording(path: String, result: MethodChannel.Result) {
        releaseRecorder()
        var record: AudioRecord? = null
        var raf: RandomAccessFile? = null
        try {
            val minBuffer = AudioRecord.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuffer <= 0) {
                result.error("record_buffer", "invalid audio buffer size", null)
                return
            }
            val bufferSize = maxOf(minBuffer * 2, 4096)
            record = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize,
            )
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                result.error("record_init", "AudioRecord is not initialized", null)
                return
            }

            File(path).parentFile?.mkdirs()
            raf = RandomAccessFile(File(path), "rw")
            raf.setLength(0)
            writeWavHeader(raf, 0)

            record.startRecording()
            audioRecord = record
            recordFile = raf
            recordPath = path
            recordSamples = 0
            recording = true

            val localRecord = record
            val localRaf = raf
            recordThread = Thread {
                val samples = ShortArray(bufferSize / 2)
                val bytes = ByteArray(samples.size * 2)
                try {
                    while (recording) {
                        val n = localRecord.read(samples, 0, samples.size)
                        if (n > 0) {
                            var j = 0
                            for (i in 0 until n) {
                                val s = samples[i].toInt()
                                bytes[j++] = (s and 0xFF).toByte()
                                bytes[j++] = ((s shr 8) and 0xFF).toByte()
                            }
                            localRaf.write(bytes, 0, n * 2)
                            recordSamples += n
                        } else if (n < 0) {
                            break
                        }
                    }
                } catch (_: Exception) {
                    // Остановка/освобождение могут прервать чтение.
                }
            }.also { it.start() }
            result.success(null)
        } catch (e: Exception) {
            recording = false
            try {
                record?.stop()
            } catch (_: Exception) {
            }
            try {
                record?.release()
            } catch (_: Exception) {
            }
            try {
                raf?.close()
            } catch (_: Exception) {
            }
            audioRecord = null
            recordFile = null
            recordPath = null
            File(path).delete()
            result.error("record_start", e.message ?: "cannot start recording", null)
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        val record = audioRecord
        val raf = recordFile
        val path = recordPath
        if (record == null || raf == null || path == null) {
            result.success(null)
            return
        }

        recording = false
        try {
            record.stop()
        } catch (_: Exception) {
        }
        try {
            recordThread?.join(1500)
        } catch (_: Exception) {
        }
        recordThread = null
        try {
            record.release()
        } catch (_: Exception) {
        }
        audioRecord = null
        recordFile = null
        recordPath = null

        val dataSize = recordSamples * 2
        try {
            writeWavHeader(raf, dataSize)
        } catch (_: Exception) {
        }
        try {
            raf.close()
        } catch (_: Exception) {
        }

        val durationMs = recordSamples * 1000 / sampleRate
        result.success(mapOf("path" to path, "durationMs" to durationMs))
    }

    private fun writeWavHeader(raf: RandomAccessFile, dataSize: Long) {
        val byteRate = sampleRate * 2 // mono, 16 bit
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray(Charsets.US_ASCII))
        header.putInt((36 + dataSize).toInt())
        header.put("WAVE".toByteArray(Charsets.US_ASCII))
        header.put("fmt ".toByteArray(Charsets.US_ASCII))
        header.putInt(16) // fmt chunk size
        header.putShort(1) // PCM
        header.putShort(1) // mono
        header.putInt(sampleRate)
        header.putInt(byteRate)
        header.putShort(2) // block align
        header.putShort(16) // bits per sample
        header.put("data".toByteArray(Charsets.US_ASCII))
        header.putInt(dataSize.toInt())
        raf.seek(0)
        raf.write(header.array())
    }

    private fun play(path: String, result: MethodChannel.Result) {
        stopPlayback()
        if (!File(path).exists()) {
            result.error("play_missing", "file not found", null)
            return
        }
        try {
            val mp = MediaPlayer()
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .build(),
            )
            mp.setDataSource(path)
            mp.setOnCompletionListener { finishPlay(null) }
            mp.setOnErrorListener { _, what, extra ->
                finishPlay("playback error $what/$extra")
                true
            }
            mp.prepare()
            player = mp
            playResult = result
            mp.start()
        } catch (e: Exception) {
            releasePlayer()
            playResult = null
            result.error("play_start", e.message ?: "cannot play", null)
        }
    }

    private fun stopPlayback() {
        val pending = playResult
        playResult = null
        releasePlayer()
        pending?.success(null)
    }

    private fun finishPlay(error: String?) {
        val pending = playResult
        playResult = null
        releasePlayer()
        if (pending != null) {
            if (error == null) {
                pending.success(null)
            } else {
                pending.error("playback", error, null)
            }
        }
    }

    private fun releasePlayer() {
        val mp = player
        player = null
        if (mp != null) {
            try {
                mp.setOnCompletionListener(null)
            } catch (_: Exception) {
            }
            try {
                mp.setOnErrorListener(null)
            } catch (_: Exception) {
            }
            try {
                mp.stop()
            } catch (_: Exception) {
            }
            try {
                mp.reset()
            } catch (_: Exception) {
            }
            try {
                mp.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun releaseRecorder() {
        val record = audioRecord
        recording = false
        try {
            record?.stop()
        } catch (_: Exception) {
        }
        try {
            recordThread?.join(1500)
        } catch (_: Exception) {
        }
        recordThread = null
        try {
            record?.release()
        } catch (_: Exception) {
        }
        try {
            recordFile?.close()
        } catch (_: Exception) {
        }
        audioRecord = null
        recordFile = null
        recordPath = null
    }

    override fun onDestroy() {
        stopPlayback()
        releaseRecorder()
        super.onDestroy()
    }
}
