package com.example.photo_uploader

/** Physical rotation, independent of Android's screen auto-rotate setting. */
object CaptureRotation {
    fun fromSensor(angle: Int, previous: Int?): Int? {
        if (angle !in 0..359) return previous
        // Keep the last quadrant when the device is held near a diagonal.
        if (previous != null) {
            val distance = (angle + previous) % 360
            if (minOf(distance, 360 - distance) <= 55) return previous
        }
        return (360 - ((angle + 45) / 90 * 90) % 360) % 360
    }
}
