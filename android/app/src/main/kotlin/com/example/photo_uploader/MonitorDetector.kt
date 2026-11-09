package com.example.photo_uploader

import org.opencv.android.OpenCVLoader
import org.opencv.core.*
import org.opencv.imgproc.Imgproc
import kotlin.math.*

/** The live guide and saved-photo crop use the same quadrilateral detector. */
object MonitorDetector {
    private val ready by lazy { try { OpenCVLoader.initLocal() } catch (_: LinkageError) { false } }
    fun available() = ready
    private fun distance(a: Point, b: Point) = hypot(a.x - b.x, a.y - b.y)

    fun fromLuminance(bytes: ByteArray, width: Int, height: Int): List<List<Double>> {
        require(width in 1..640 && height in 1..640 && bytes.size == width * height)
        if (!available()) error("이미지 처리 엔진을 사용할 수 없습니다.")
        val gray = Mat(height, width, CvType.CV_8UC1)
        return try {
            gray.put(0, 0, bytes)
            findCorners(gray)?.map { listOf(it.x / width, it.y / height) } ?: emptyList()
        } finally { gray.release() }
    }

    fun findCorners(image: Mat): List<Point>? {
        val sample = Mat(); val gray = Mat(); val edges = Mat(); val hierarchy = Mat()
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 3.0))
        val contours = mutableListOf<MatOfPoint>()
        val scale = min(1.0, 1000.0 / max(image.cols(), image.rows()))
        try {
            Imgproc.resize(image, sample, Size(), scale, scale, Imgproc.INTER_AREA)
            if (sample.channels() == 1) sample.copyTo(gray)
            else Imgproc.cvtColor(sample, gray, Imgproc.COLOR_RGBA2GRAY)
            Imgproc.GaussianBlur(gray, gray, Size(5.0, 5.0), 0.0)
            Imgproc.Canny(gray, edges, 40.0, 140.0)
            Imgproc.morphologyEx(edges, edges, Imgproc.MORPH_CLOSE, kernel)
            Imgproc.findContours(edges, contours, hierarchy, Imgproc.RETR_LIST, Imgproc.CHAIN_APPROX_SIMPLE)
            val area = sample.rows().toDouble() * sample.cols()
            for (contour in contours.sortedByDescending { Imgproc.contourArea(it) }) {
                if (Imgproc.contourArea(contour) !in area * 0.28..area * 0.96) continue
                val curve = MatOfPoint2f(*contour.toArray()); val polygon = MatOfPoint2f()
                try {
                    Imgproc.approxPolyDP(curve, polygon, 0.02 * Imgproc.arcLength(curve, true), true)
                    if (polygon.total() != 4L) continue
                    val integer = MatOfPoint(*polygon.toArray())
                    val convex = try { Imgproc.isContourConvex(integer) } finally { integer.release() }
                    if (!convex || Imgproc.pointPolygonTest(polygon,
                        Point(sample.cols() / 2.0, sample.rows() / 2.0), false) < 0) continue
                    val points = polygon.toArray()
                    val cx = points.sumOf { it.x } / 4; val cy = points.sumOf { it.y } / 4
                    val ordered = points.sortedBy { atan2(it.y - cy, it.x - cx) }
                    val start = ordered.indices.minBy { ordered[it].x + ordered[it].y }
                    val corners = List(4) { ordered[(start + it) % 4] }
                    if (corners.indices.any { i ->
                        val a = corners[(i + 3) % 4]; val b = corners[i]; val c = corners[(i + 1) % 4]
                        abs((a.x - b.x) * (c.x - b.x) + (a.y - b.y) * (c.y - b.y)) /
                            max(1.0, distance(a, b) * distance(c, b)) > 0.65
                    }) continue
                    return corners.map { Point(it.x / scale, it.y / scale) }
                } finally { curve.release(); polygon.release() }
            }
            return null
        } finally {
            contours.forEach { it.release() }
            sample.release(); gray.release(); edges.release(); hierarchy.release(); kernel.release()
        }
    }
}
