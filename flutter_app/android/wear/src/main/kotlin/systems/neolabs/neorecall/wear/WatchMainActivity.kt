package systems.neolabs.neorecall.wear

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.os.Build
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ImageView
import android.widget.Space
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import systems.neolabs.neorecall.wear.recording.WatchRecordingService
import systems.neolabs.neorecall.wear.storage.WatchRecordingStore
import systems.neolabs.neorecall.wear.sync.WatchSyncManager

class WatchMainActivity : Activity() {
  private lateinit var status: TextView
  private lateinit var pending: TextView
  private lateinit var action: TextView
  private var receiverRegistered = false

  private val stateReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) = refresh()
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    setContentView(buildContent())
    action.setOnClickListener {
      if (WatchRecordingService.isRecording(this)) stopRecording() else requestStart()
    }
    WatchSyncManager.get(this).syncPending(includeEnqueued = true)
  }

  override fun onStart() {
    super.onStart()
    ContextCompat.registerReceiver(
      this,
      stateReceiver,
      IntentFilter(WatchRecordingService.ACTION_STATE_CHANGED),
      ContextCompat.RECEIVER_NOT_EXPORTED,
    )
    receiverRegistered = true
    refresh()
  }

  override fun onStop() {
    if (receiverRegistered) unregisterReceiver(stateReceiver)
    receiverRegistered = false
    super.onStop()
  }

  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, results: IntArray) {
    super.onRequestPermissionsResult(requestCode, permissions, results)
    if (requestCode == MIC_PERMISSION &&
      ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    ) {
      startRecording()
    }
  }

  private fun requestStart() {
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
      startRecording()
    } else {
      val permissions = buildList {
        add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          add(Manifest.permission.POST_NOTIFICATIONS)
        }
      }
      ActivityCompat.requestPermissions(this, permissions.toTypedArray(), MIC_PERMISSION)
    }
  }

  private fun startRecording() {
    ContextCompat.startForegroundService(
      this,
      Intent(this, WatchRecordingService::class.java).setAction(WatchRecordingService.ACTION_START),
    )
    refresh()
  }

  private fun stopRecording() {
    startService(Intent(this, WatchRecordingService::class.java).setAction(WatchRecordingService.ACTION_STOP))
    refresh()
  }

  private fun refresh() {
    val recording = WatchRecordingService.isRecording(this)
    status.text = if (recording) "Recording in background" else "Ready to remember"
    action.text = if (recording) "STOP" else "START"
    action.setBackgroundResource(
      if (recording) R.drawable.watch_record_button_live else R.drawable.watch_record_button_ready,
    )
    pending.text = when (val count = WatchRecordingStore.get(this).pendingCount()) {
      0 -> "All recordings synced"
      1 -> "1 recording safely stored"
      else -> "$count recordings safely stored"
    }
  }

  private fun buildContent(): LinearLayout {
    val density = resources.displayMetrics.density
    fun dp(value: Int) = (value * density).toInt()
    return LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      setPadding(dp(20), dp(14), dp(20), dp(14))
      setBackgroundColor(Color.rgb(7, 17, 12))
      addView(
        LinearLayout(context).apply {
          orientation = LinearLayout.HORIZONTAL
          gravity = Gravity.CENTER
          addView(
            ImageView(context).apply {
              setImageResource(R.drawable.neorecall_logo)
              contentDescription = "NeoRecall logo"
            },
            LinearLayout.LayoutParams(dp(40), dp(40)),
          )
          addView(TextView(context).apply {
            text = "NEORECALL"
            textSize = 12f
            setTextColor(Color.rgb(233, 183, 86))
            letterSpacing = 0.18f
            gravity = Gravity.CENTER
            setPadding(dp(8), 0, 0, 0)
          })
        },
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(44)),
      )
      status = TextView(context).apply {
        textSize = 15f
        setTextColor(Color.WHITE)
        gravity = Gravity.CENTER
        setPadding(0, dp(7), 0, dp(10))
      }
      addView(status)
      action = TextView(context).apply {
        textSize = 15f
        setTextColor(Color.rgb(7, 17, 12))
        gravity = Gravity.CENTER
        isClickable = true
        isFocusable = true
      }
      addView(action, LinearLayout.LayoutParams(dp(92), dp(92)))
      addView(Space(context), LinearLayout.LayoutParams(1, dp(9)))
      pending = TextView(context).apply {
        textSize = 11f
        setTextColor(Color.rgb(172, 190, 179))
        gravity = Gravity.CENTER
      }
      addView(pending, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
  }

  companion object { private const val MIC_PERMISSION = 71 }
}
