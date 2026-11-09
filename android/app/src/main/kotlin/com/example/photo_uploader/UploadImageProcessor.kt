package com.example.photo_uploader

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.os.Build
import androidx.exifinterface.media.ExifInterface
import org.opencv.android.Utils
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.io.File
import java.util.UUID
import java.security.MessageDigest
import org.json.JSONObject
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Creates a single, smaller upload file. Never changes the source/original. */
object UploadImageProcessor {
    private fun hash(stamp: String) = MessageDigest.getInstance("SHA-256")
        .digest(stamp.toByteArray()).joinToString("") { "%02x".format(it) }

    /** Remove only this photo's derived files, including pre-upgrade caches. */
    fun forget(source: File, directory: File) {
        val identity = "${source.path}:${source.length()}:${source.lastModified()}"
        val stamps = listOf(false, true).flatMap { optimize ->
            listOf("v1:$identity:$optimize") + listOf(false, true).flatMap { crop ->
                listOf("v2:$identity:$optimize:$crop") + listOf(false, true).map { keepCrop -> "v3:$identity:$optimize:$crop:$keepCrop" }
            }
        }
        for (stamp in stamps) {
            val metadata = File(directory, "${hash(stamp)}.json")
            if (!metadata.isFile) continue
            try {
                val derived = File(JSONObject(metadata.readText()).getString("path"))
                if (derived.canonicalFile.parentFile == directory.canonicalFile) derived.delete()
            } catch (_: Exception) { /* Corrupt metadata must not prevent original cleanup. */ }
            metadata.delete()
        }
    }

    fun prepare(source: File, name: String, directory: File, optimize: Boolean, crop: Boolean = true,
                keepCrop: Boolean = false): Map<String, Any> {
        val stamp = "v3:${source.path}:${source.length()}:${source.lastModified()}:$optimize:$crop:$keepCrop"
        val key = hash(stamp)
        directory.mkdirs()
        val metadata = File(directory, "$key.json")
        if (metadata.isFile) {
            try {
                val data = JSONObject(metadata.readText())
                if (File(data.getString("path")).isFile) return mapOf(
                    "path" to data.getString("path"), "name" to data.getString("name"),
                    "sourceBytes" to data.getLong("sourceBytes"), "uploadBytes" to data.getLong("uploadBytes"),
                    "cropped" to data.getBoolean("cropped"), "note" to data.getString("note"))
            } catch (_: Exception) { /* Recreate an expired/corrupt cache entry. */ }
        }
        val result = prepareUncached(source, name, directory, optimize, crop, keepCrop)
        try {
            metadata.writeText(JSONObject(result).toString())
        } catch (error: Exception) {
            val derived = File(result.getValue("path") as String)
            if (derived.canonicalFile.parentFile == directory.canonicalFile) derived.delete()
            metadata.delete()
            throw error
        }
        return result
    }

    private fun prepareUncached(source: File, name: String, directory: File, optimize: Boolean, crop: Boolean,
                                keepCrop: Boolean): Map<String, Any> {
        val sourceBytes = source.length()
        fun original(reason: String = "") = mapOf<String, Any>(
            "path" to source.path, "name" to name, "sourceBytes" to sourceBytes,
            "uploadBytes" to sourceBytes, "cropped" to false, "note" to reason)
        if (!optimize) return original()
        val bitmap = try { decode(source, 2560) }
            catch (_: OutOfMemoryError) { return original("이미지 처리 메모리가 부족하여 원본 전송") }
            catch (_: Exception) { null }
            ?: return original("가공을 지원하지 않는 형식: 원본 전송")
        try {
            if (!MonitorDetector.available()) {
                bitmap.recycle()
                return original("이미지 처리 엔진을 사용할 수 없어 원본 전송")
            }
        } catch (_: LinkageError) {
            bitmap.recycle()
            return original("이미지 처리 엔진을 사용할 수 없어 원본 전송")
        }
        val image = Mat()
        var result: Mat? = null
        var outputBitmap: Bitmap? = null
        var output: File? = null
        try {
            Utils.bitmapToMat(bitmap, image)
            bitmap.recycle()
            result = if (crop) cropScreen(image) else null
            if (keepCrop && result == null) return original(if (crop)
                "모니터 테두리 미검출 · 전체 사진 보관" else "크롭 없이 전체 사진 보관")
            val pixels = result ?: image
            val encodedBitmap = Bitmap.createBitmap(pixels.cols(), pixels.rows(), Bitmap.Config.ARGB_8888)
            outputBitmap = encodedBitmap
            Utils.matToBitmap(pixels, encodedBitmap)
            directory.mkdirs()
            output = File(directory, "${UUID.randomUUID()}.jpg")
            output.outputStream().use { stream ->
                check(encodedBitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream)) { "JPEG 생성 실패" }
                stream.fd.sync()
            }
            // Cropping/re-encoding an already optimized PNG or JPEG can increase
            // its size. In that case transmit the smaller original, once.
            if (output.length() >= sourceBytes && !(keepCrop && result != null)) {
                output.delete()
                return original("가공본보다 작은 원본 전송")
            }
            return mapOf("path" to output.path,
                "name" to "${File(name).nameWithoutExtension}.jpg",
                "sourceBytes" to sourceBytes, "uploadBytes" to output.length(),
                "cropped" to (result != null), "note" to "")
        } catch (error: Exception) {
            output?.delete()
            throw error
        } catch (_: OutOfMemoryError) {
            output?.delete()
            return original("이미지 처리 메모리가 부족하여 원본 전송")
        } finally {
            if (!bitmap.isRecycled) bitmap.recycle()
            outputBitmap?.recycle()
            result?.release()
            image.release()
        }
    }

    private fun decode(source: File, maxEdge: Int): Bitmap? {
        if (Build.VERSION.SDK_INT >= 28) {
            return ImageDecoder.decodeBitmap(ImageDecoder.createSource(source)) { decoder, info, _ ->
                val scale = min(1.0, maxEdge.toDouble() / max(info.size.width, info.size.height))
                decoder.setTargetSize(max(1, (info.size.width * scale).roundToInt()),
                    max(1, (info.size.height * scale).roundToInt()))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.isMutableRequired = true
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
            }
        }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.path, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return null
        options.inJustDecodeBounds = false
        options.inSampleSize = 1
        while (max(options.outWidth, options.outHeight) / options.inSampleSize > maxEdge) options.inSampleSize *= 2
        val bitmap = BitmapFactory.decodeFile(source.path, options) ?: return null
        val matrix = Matrix()
        val orientation = try {
            ExifInterface(source).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (_: Exception) { ExifInterface.ORIENTATION_NORMAL }
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> { matrix.setRotate(180f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(-90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(270f)
        }
        if (matrix.isIdentity) return bitmap
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true).also {
            if (it !== bitmap) bitmap.recycle()
        }
    }

    private fun distance(a: Point, b: Point) = hypot(a.x - b.x, a.y - b.y)

    private fun cropScreen(image: Mat): Mat? {
        val full = MonitorDetector.findCorners(image) ?: return null
        val width = max(distance(full[0], full[1]), distance(full[3], full[2])).roundToInt()
        val height = max(distance(full[0], full[3]), distance(full[1], full[2])).roundToInt()
        if (min(width, height) < 200 || width.toDouble() / height !in 0.3..4.0) return null
        val factor = min(1.0, 2560.0 / max(width, height))
        val outWidth = max(1, (width * factor).roundToInt())
        val outHeight = max(1, (height * factor).roundToInt())
        val from = MatOfPoint2f(*full.toTypedArray())
        val to = MatOfPoint2f(Point(0.0, 0.0), Point(outWidth - 1.0, 0.0),
            Point(outWidth - 1.0, outHeight - 1.0), Point(0.0, outHeight - 1.0))
        val transform = Imgproc.getPerspectiveTransform(from, to)
        val cropped = Mat()
        try {
            Imgproc.warpPerspective(image, cropped, transform, Size(outWidth.toDouble(), outHeight.toDouble()))
            return cropped
        } catch (error: Exception) {
            cropped.release()
            throw error
        } finally { from.release(); to.release(); transform.release() }
    }
}
