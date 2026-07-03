package com.noop.ui

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

// MARK: - LiquidMotion — the one shared tilt source (Android port of LiquidCore.swift's LiquidMotion)
//
// iOS reads device attitude via CMMotionManager (no permission prompt). Android has no equivalent
// built in, so this is a fresh SensorManager implementation with the SAME public shape and smoothing
// as the Swift original: a process-wide singleton exposing a plain `tilt` read (NOT observable state,
// so the per-frame Canvas redraw is what advances the picture, never a recomposition storm),
// ref-counted so the sensor only runs while a liquid view is on screen.
//
// `tilt` is a single Double written from the sensor callback thread and read from the Canvas draw on
// the main thread; @Volatile gives visibility and an 8-byte read/write is atomic, so a one-frame-stale
// value is harmless for a decorative slosh — exactly the iOS rationale.

object LiquidMotion : SensorEventListener {

    /** Mirrors the iOS `LiquidMotion.shared` accessor so call sites read `LiquidMotion.shared.tilt`. */
    val shared: LiquidMotion get() = this

    /** Smoothed world tilt (roll) in radians, clamped ±0.62. Plain read — no publishing. */
    @Volatile
    var tilt: Double = 0.0
        private set

    private var sensorManager: SensorManager? = null
    private var sensor: Sensor? = null
    private var started = false
    private var refCount = 0

    // Scratch buffers reused across events (rotation-vector path).
    private val rotationMatrix = FloatArray(9)
    private val orientation = FloatArray(3)

    /**
     * Ref-counted start. Registers the rotation-vector listener on first acquire. A Context is required
     * on Android (unlike iOS); only the applicationContext is retained, so there is no Activity/Composable
     * leak. Callers pair this with [release] from a DisposableEffect (iOS .onAppear/.onDisappear).
     */
    @Synchronized
    fun acquire(context: Context) {
        refCount += 1
        if (started) return
        val sm = context.applicationContext.getSystemService(Context.SENSOR_SERVICE) as? SensorManager ?: return
        // Prefer the fused rotation vector (cleanest roll); fall back to the raw accelerometer.
        val s = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
            ?: sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            ?: return
        sensorManager = sm
        sensor = s
        started = true
        // ~50Hz (GAME) ≈ the iOS 60Hz deviceMotionUpdateInterval; enough for a smooth slosh.
        sm.registerListener(this, s, SensorManager.SENSOR_DELAY_GAME)
    }

    /** Ref-counted stop. Unregisters and resets tilt to level once the last liquid view leaves. */
    @Synchronized
    fun release() {
        refCount = max(0, refCount - 1)
        if (refCount != 0 || !started) return
        started = false
        sensorManager?.unregisterListener(this)
        sensorManager = null
        sensor = null
        tilt = 0.0
    }

    override fun onSensorChanged(event: SensorEvent) {
        val raw: Double = when (event.sensor.type) {
            Sensor.TYPE_ROTATION_VECTOR -> {
                SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
                SensorManager.getOrientation(rotationMatrix, orientation)
                // orientation[2] = roll ≈ side-to-side tilt of a phone held upright (the iOS attitude.roll).
                orientation[2].toDouble()
            }
            Sensor.TYPE_ACCELEROMETER -> {
                // Fallback: derive roll from the gravity vector.
                val x = event.values[0].toDouble()
                val y = event.values[1].toDouble()
                val z = event.values[2].toDouble()
                atan2(x, sqrt(y * y + z * z))
            }
            else -> return
        }
        // Same clamp + light smoothing as iOS (LiquidCore.swift:94-95). If the slosh ever reads mirrored
        // vs the device tilt on hardware, negate `raw` here — a one-character, purely-cosmetic axis flip.
        val clamped = max(-0.62, min(0.62, raw))
        tilt += (clamped - tilt) * 0.18
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) { /* no-op */ }
}
