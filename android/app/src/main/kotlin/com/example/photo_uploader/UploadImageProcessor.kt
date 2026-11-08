package com.example.photo_uploader

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.os.Build
import androidx.exifinterface.media.ExifInterface
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.io.File
import java.util.UUID
import java.security.MessageDigest
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Creates a single, smaller upload file. Never changes the source/original. */
object UploadImageProcessor {
    fun prepare(source: File, name: String, directory: File, optimize: Boolean): Map<String, Any> {
        val stamp = "v1:${source.path}:${source.length()}:${source.lastModified()}:$optimize"
        val key = MessageDigest.getInstance("SHA-256").digest(stamp.toByteArray()).joinToString("") { "%02x".format(it) }
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
        val result = prepareUncached(source, name, directory, optimize)
        metadata.writeText(JSONObject(result).toString())
        return result
    }

    private fun prepareUncached(source: File, name: String, directory: File, optimize: Boolean): Map<String, Any> {
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
            if (!OpenCVLoader.initLocal()) {
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
            result = cropScreen(image)
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
            if (output.length() >= sourceBytes) {
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
        val sample = Mat()
        val gray = Mat()
        val edges = Mat()
        val hierarchy = Mat()
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 3.0))
        val contours = mutableListOf<MatOfPoint>()
        val scale = min(1.0, 1000.0 / max(image.cols(), image.rows()))
        try {
            Imgproc.resize(image, sample, Size(), scale, scale, Imgproc.INTER_AREA)
            Imgproc.cvtColor(sample, gray, Imgproc.COLOR_RGBA2GRAY)
            Imgproc.GaussianBlur(gray, gray, Size(5.0, 5.0), 0.0)
            Imgproc.Canny(gray, edges, 40.0, 140.0)
            Imgproc.morphologyEx(edges, edges, Imgproc.MORPH_CLOSE, kernel)
            Imgproc.findContours(edges, contours, hierarchy, Imgproc.RETR_LIST, Imgproc.CHAIN_APPROX_SIMPLE)
            val totalArea = sample.rows().toDouble() * sample.cols()
            for (contour in contours.sortedByDescending { Imgproc.contourArea(it) }) {
                if (Imgproc.contourArea(contour) !in totalArea * 0.28..totalArea * 0.96) continue
                val curve = MatOfPoint2f(*contour.toArray())
                val polygon = MatOfPoint2f()
                try {
                    Imgproc.approxPolyDP(curve, polygon, 0.02 * Imgproc.arcLength(curve, true), true)
                    if (polygon.total() != 4L) continue
                    val integerPolygon = MatOfPoint(*polygon.toArray())
                    val convex = try { Imgproc.isContourConvex(integerPolygon) } finally { integerPolygon.release() }
                    if (!convex || Imgproc.pointPolygonTest(polygon,
                            Point(sample.cols() / 2.0, sample.rows() / 2.0), false) < 0) continue
                    val points = polygon.toArray()
                    val cx = points.sumOf { it.x } / 4
                    val cy = points.sumOf { it.y } / 4
                    val ordered = points.sortedBy { atan2(it.y - cy, it.x - cx) }
                    val start = ordered.indices.minBy { ordered[it].x + ordered[it].y }
                    val corners = List(4) { ordered[(start + it) % 4] }
                    if (corners.indices.any { i ->
                            val a = corners[(i + 3) % 4]; val b = corners[i]; val c = corners[(i + 1) % 4]
                            abs((a.x - b.x) * (c.x - b.x) + (a.y - b.y) * (c.y - b.y)) /
                                max(1.0, distance(a, b) * distance(c, b)) > 0.65
                        }) continue
                    val full = corners.map { Point(it.x / scale, it.y / scale) }
                    val width = max(distance(full[0], full[1]), distance(full[3], full[2])).roundToInt()
                    val height = max(distance(full[0], full[3]), distance(full[1], full[2])).roundToInt()
                    if (min(width, height) < 200 || width.toDouble() / height !in 0.3..4.0) continue
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
                } finally { curve.release(); polygon.release() }
            }
            return null
        } finally {
            contours.forEach { it.release() }
            sample.release(); gray.release(); edges.release(); hierarchy.release(); kernel.release()
        }
    }
}
