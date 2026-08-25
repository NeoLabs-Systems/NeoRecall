package systems.neolabs.neorecall.wear.recording

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import systems.neolabs.neorecall.wear.protocol.WearTransferProtocol
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.sqrt

data class CapturedWatchChunk(
  val recordingId: String,
  val sequence: Int,
  val startedAtMs: Long,
  val monotonicOffsetMs: Long,
  val durationMs: Long,
  val file: File,
  val isFinal: Boolean,
)

/** Continuous AudioRecord -> AAC/ADTS encoder with independently durable chunks. */
class AacChunkRecorder(
  context: Context,
  private val sessionId: String,
  private val sourceId: String,
  private val sessionStartedAtMs: Long,
  startingSequence: Int,
  private val startingOffsetMs: Long,
  private val onChunk: (CapturedWatchChunk) -> Unit,
  private val onFailure: (Throwable) -> Unit,
) {
  private val directory = File(context.filesDir, "watch_audio").apply { mkdirs() }
  private val running = AtomicBoolean(false)
  private var worker: Thread? = null
  private var audioRecord: AudioRecord? = null
  private var codec: MediaCodec? = null
  private var sequence = startingSequence

  fun start() {
    check(running.compareAndSet(false, true)) { "Recorder is already running." }
    worker = thread(name = "NeoRecall-watch-recorder") {
      try {
        capture()
      } catch (error: Throwable) {
        onFailure(error)
      } finally {
        running.set(false)
      }
    }
  }

  fun stopAndJoin() {
    running.set(false)
    runCatching { audioRecord?.stop() }
    worker?.join(10_000)
  }

  private fun capture() {
    val minimum = AudioRecord.getMinBufferSize(
      WearTransferProtocol.SAMPLE_RATE,
      AudioFormat.CHANNEL_IN_MONO,
      AudioFormat.ENCODING_PCM_16BIT,
    )
    val inputSize = max(minimum, WearTransferProtocol.SAMPLE_RATE * 2)
    val recorder = AudioRecord.Builder()
      .setAudioSource(MediaRecorder.AudioSource.MIC)
      .setAudioFormat(
        AudioFormat.Builder()
          .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
          .setSampleRate(WearTransferProtocol.SAMPLE_RATE)
          .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
          .build(),
      )
      .setBufferSizeInBytes(inputSize * 2)
      .build()
    check(recorder.state == AudioRecord.STATE_INITIALIZED) { "Watch microphone could not initialize." }

    val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    encoder.configure(
      MediaFormat.createAudioFormat(
        MediaFormat.MIMETYPE_AUDIO_AAC,
        WearTransferProtocol.SAMPLE_RATE,
        WearTransferProtocol.CHANNELS,
      ).apply {
        setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        setInteger(MediaFormat.KEY_BIT_RATE, WearTransferProtocol.AAC_BIT_RATE)
        setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, inputSize)
      },
      null,
      null,
      MediaCodec.CONFIGURE_FLAG_ENCODE,
    )
    audioRecord = recorder
    codec = encoder
    encoder.start()
    recorder.startRecording()

    var totalSamples = startingOffsetMs * WearTransferProtocol.SAMPLE_RATE / 1000
    var output: BufferedOutputStream? = null
    var rawOutput: FileOutputStream? = null
    var partial: File? = null
    var chunkOffsetMs = startingOffsetMs
    var chunkFirstPtsUs = startingOffsetMs * 1000
    var lastPtsUs = chunkFirstPtsUs
    var wroteAudio = false
    var voicedMs = 0L
    val info = MediaCodec.BufferInfo()

    fun openChunk() {
      partial = File(
        directory,
        "${sessionId}_${sourceId}_${sequence}_${sessionStartedAtMs}_${chunkOffsetMs}.partial",
      )
      rawOutput = FileOutputStream(partial!!)
      output = BufferedOutputStream(rawOutput!!)
      wroteAudio = false
      voicedMs = 0L
    }

    fun finishChunk(final: Boolean) {
      val source = partial ?: return
      val stream = output ?: return
      stream.flush()
      rawOutput?.fd?.sync()
      stream.close()
      output = null
      rawOutput = null
      partial = null
      val durationMs = max(1L, (lastPtsUs - chunkFirstPtsUs) / 1000L + 64L)
      val retain = wroteAudio &&
        source.length() > 0L &&
        voicedMs >= WearTransferProtocol.VAD_MIN_VOICED_MS
      if (!retain) {
        source.delete()
      } else {
        val complete = File(source.parentFile, "${UUID.randomUUID()}.aac")
        check(source.renameTo(complete)) { "Watch audio could not be finalized." }
        onChunk(
          CapturedWatchChunk(
            recordingId = complete.nameWithoutExtension,
            sequence = sequence,
            startedAtMs = sessionStartedAtMs + chunkOffsetMs,
            monotonicOffsetMs = chunkOffsetMs,
            durationMs = durationMs,
            file = complete,
            isFinal = final,
          ),
        )
      }
      sequence += 1
      chunkOffsetMs += durationMs
      chunkFirstPtsUs = chunkOffsetMs * 1000
      lastPtsUs = chunkFirstPtsUs
    }

    fun drain(endOfStream: Boolean) {
      while (true) {
        val index = encoder.dequeueOutputBuffer(info, if (endOfStream) 10_000 else 0)
        if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
          if (!endOfStream) return
          continue
        }
        if (index < 0) continue
        val buffer = encoder.getOutputBuffer(index)
        val codecConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
        if (!codecConfig && info.size > 0 && buffer != null) {
          if (output == null) openChunk()
          if (wroteAudio && info.presentationTimeUs - chunkFirstPtsUs >= WearTransferProtocol.CHUNK_DURATION_MS * 1000) {
            finishChunk(false)
            openChunk()
          }
          buffer.position(info.offset)
          buffer.limit(info.offset + info.size)
          output!!.write(adtsHeader(info.size + 7))
          val bytes = ByteArray(info.size)
          buffer.get(bytes)
          output!!.write(bytes)
          wroteAudio = true
          lastPtsUs = info.presentationTimeUs
        }
        val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
        encoder.releaseOutputBuffer(index, false)
        if (eos) return
      }
    }

    openChunk()
    try {
      while (running.get()) {
        val inputIndex = encoder.dequeueInputBuffer(10_000)
        if (inputIndex >= 0) {
          val buffer = encoder.getInputBuffer(inputIndex) ?: continue
          buffer.clear()
          val read = recorder.read(buffer, minOf(buffer.capacity(), inputSize), AudioRecord.READ_BLOCKING)
          if (read > 0) {
            val samplesRead = read / 2
            var energy = 0.0
            for (sampleIndex in 0 until samplesRead) {
              val sample = buffer.getShort(sampleIndex * 2).toDouble()
              energy += sample * sample
            }
            if (samplesRead > 0 && sqrt(energy / samplesRead) >= WearTransferProtocol.VAD_MIN_RMS) {
              voicedMs += samplesRead * 1000L / WearTransferProtocol.SAMPLE_RATE
            }
            val ptsUs = totalSamples * 1_000_000L / WearTransferProtocol.SAMPLE_RATE
            totalSamples += read / 2
            encoder.queueInputBuffer(inputIndex, 0, read, ptsUs, 0)
          }
        }
        drain(false)
      }
      val eosIndex = encoder.dequeueInputBuffer(100_000)
      if (eosIndex >= 0) {
        val ptsUs = totalSamples * 1_000_000L / WearTransferProtocol.SAMPLE_RATE
        encoder.queueInputBuffer(eosIndex, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drain(true)
      }
      finishChunk(true)
    } finally {
      runCatching { recorder.stop() }
      recorder.release()
      runCatching { encoder.stop() }
      encoder.release()
      audioRecord = null
      codec = null
      output?.close()
      rawOutput = null
    }
  }

  private fun adtsHeader(packetLength: Int): ByteArray {
    val profile = 1 // AAC Low Complexity in the two-bit ADTS profile field.
    val frequencyIndex = 8 // 16 kHz.
    val channels = WearTransferProtocol.CHANNELS
    return byteArrayOf(
      0xFF.toByte(),
      0xF1.toByte(),
      ((profile shl 6) or (frequencyIndex shl 2) or (channels shr 2)).toByte(),
      (((channels and 3) shl 6) or (packetLength shr 11)).toByte(),
      ((packetLength and 0x7FF) shr 3).toByte(),
      (((packetLength and 7) shl 5) or 0x1F).toByte(),
      0xFC.toByte(),
    )
  }

  companion object {
    /** Salvages complete ADTS frames left by an abrupt process/device stop. */
    fun recoverPartial(
      context: Context,
      sessionId: String,
      sourceId: String,
      sessionStartedAtMs: Long,
      sequence: Int,
      monotonicOffsetMs: Long,
      isFinal: Boolean,
    ): CapturedWatchChunk? {
      val directory = File(context.filesDir, "watch_audio")
      val partial = File(
        directory,
        "${sessionId}_${sourceId}_${sequence}_${sessionStartedAtMs}_${monotonicOffsetMs}.partial",
      )
      if (!partial.exists()) return null
      var frames = 0L
      var validBytes = 0L
      RandomAccessFile(partial, "rw").use { file ->
        val header = ByteArray(7)
        while (file.filePointer + 7 <= file.length()) {
          file.readFully(header)
          if ((header[0].toInt() and 0xFF) != 0xFF ||
            (header[1].toInt() and 0xF0) != 0xF0
          ) break
          val frameLength = ((header[3].toInt() and 0x03) shl 11) or
            ((header[4].toInt() and 0xFF) shl 3) or
            ((header[5].toInt() and 0xE0) shr 5)
          if (frameLength < 7 || validBytes + frameLength > file.length()) break
          validBytes += frameLength
          frames += 1
          file.seek(validBytes)
        }
        file.setLength(validBytes)
        file.fd.sync()
      }
      if (validBytes == 0L) {
        partial.delete()
        return null
      }
      val complete = File(directory, "${UUID.randomUUID()}.aac")
      check(partial.renameTo(complete)) { "Recovered watch audio could not be finalized." }
      return CapturedWatchChunk(
        recordingId = complete.nameWithoutExtension,
        sequence = sequence,
        startedAtMs = sessionStartedAtMs + monotonicOffsetMs,
        monotonicOffsetMs = monotonicOffsetMs,
        durationMs = max(1L, frames * 1024L * 1000L / WearTransferProtocol.SAMPLE_RATE),
        file = complete,
        isFinal = isFinal,
      )
    }
  }
}
