package com.example.photo_uploader

import android.Manifest
import android.app.AlertDialog
import android.app.RecoverableSecurityException
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.view.OrientationEventListener
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

/** Keep document URIs: image_picker's cache paths cannot identify originals. */
class MainActivity : FlutterActivity() {
    private class DeletionCancelled(message: String) : IllegalStateException(message)
    companion object {
        private const val CHANNEL = "photo_uploader/originals"
        private const val PICK = 4101
        private const val DELETE = 4102
        private const val LEGACY_DELETE = 4103
        private const val CAMERA_STORAGE = 4105
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val detectorWorker = Executors.newSingleThreadExecutor()
    private val state by lazy { getSharedPreferences("original_photos", MODE_PRIVATE) }
    private var pending: MethodChannel.Result? = null
    private var legacyItem: JSONObject? = null
    private var captureRotation: Int? = null
    private val orientationListener by lazy {
        object : OrientationEventListener(this) {
            override fun onOrientationChanged(angle: Int) {
                // Sensor degrees are clockwise; CameraX target rotations are
                // counter-clockwise relative to the device's natural position.
                if (angle == ORIENTATION_UNKNOWN) return
                captureRotation = CaptureRotation.fromSensor(angle, captureRotation)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        captureRotation = null
        if (orientationListener.canDetectOrientation()) orientationListener.enable()
    }

    override fun onPause() {
        orientationListener.disable()
        super.onPause()
    }

    @Suppress("DEPRECATION")
    private fun captureOrientation(): String {
        val rotation = captureRotation ?: when (windowManager.defaultDisplay.rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        return when (rotation) {
            90 -> "landscapeLeft"
            180 -> "portraitDown"
            270 -> "landscapeRight"
            else -> "portraitUp"
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "photo_uploader/monitor")
            .setMethodCallHandler { call, result ->
                if (call.method != "detect") result.notImplemented()
                else {
                    val bytes = call.argument<ByteArray>("bytes")
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    if (bytes == null) result.error("INVALID_FRAME", "카메라 프레임이 없습니다.", null)
                    else detectorWorker.execute {
                        try {
                            val corners = MonitorDetector.fromLuminance(bytes, width, height)
                            runOnUiThread { result.success(corners) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("DETECT_FAILED", error.message, null) }
                        }
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "captureOrientation") {
                    result.success(captureOrientation())
                    return@setMethodCallHandler
                }
                if (pending != null) {
                    result.error("BUSY", "다른 사진 작업을 처리 중입니다.", null)
                    return@setMethodCallHandler
                }
                if (state.contains("discardPaths") && call.method !in setOf("recover", "discardPhotos")) {
                    result.error("DELETE_PENDING", "선택한 사진의 삭제를 먼저 완료하세요.", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "recover" -> runWork(result) {
                        var warning: String? = null
                        try {
                            state.getString("cameraImport", null)?.let {
                                importCameraPhoto(JSONObject(it).getString("path"))
                            }
                            recoverCameraPhoto()
                        } catch (error: Exception) {
                            // A failed old external-camera output must not hide
                            // all previously selected photos or block the app.
                            warning = "이전 촬영 복구 미완료: ${error.message}"
                        }
                        cleanDiscarded(false)
                        selection() + mapOf("warning" to warning)
                    }
                    "prepareCamera" -> {
                        if (state.getBoolean("uploaded", false)) {
                            result.error("UPLOADED", "전송한 사진의 처리를 먼저 완료하세요.", null)
                        } else {
                            pending = result
                            if (Build.VERSION.SDK_INT < 29 &&
                                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                                requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), CAMERA_STORAGE)
                            } else succeed(null)
                        }
                    }
                    "registerCapture" -> {
                        if (state.getBoolean("uploaded", false)) {
                            result.error("UPLOADED", "전송한 사진의 처리를 먼저 완료하세요.", null)
                        } else {
                            val path = call.argument<String>("path")
                            if (path == null) result.error("INVALID_PATH", "촬영 파일이 없습니다.", null)
                            else runWork(result) { importCameraPhoto(path, call.argument<Boolean>("cropMonitor") != false); selection() }
                        }
                    }
                    "prepareUpload" -> {
                        val path = call.argument<String>("path")
                        val photo = records().find { it.getString("path") == path }
                        if (photo == null || state.getBoolean("uploaded", false)) {
                            result.error("INVALID_PHOTO", "전송할 선택 사진이 없습니다.", null)
                        } else runWork(result) {
                            UploadImageProcessor.prepare(File(photo.getString("path")), photo.getString("name"),
                                File(cacheDir, "upload_prepared"), call.argument<Boolean>("optimize") == true,
                                photo.optBoolean("cropMonitor", true))
                        }
                    }
                    "pick" -> {
                        if (state.getBoolean("uploaded", false)) {
                            result.error("UPLOADED", "전송한 사진의 삭제를 먼저 완료하세요.", null)
                        } else {
                            pending = result
                            try {
                                // SAF grants access to the selected original documents, with
                                // no broad gallery/storage permission required.
                                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    type = "image/*"
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                                    putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                                }, PICK)
                            } catch (error: Exception) {
                                fail(error)
                            }
                        }
                    }
                    "acknowledgeUpload" -> runWork(result) {
                        check(records().isNotEmpty()) { "선택한 원본 정보가 없습니다." }
                        check(state.edit().putBoolean("uploaded", true)
                            .putBoolean("deleteOriginals", call.argument<Boolean>("deleteOriginals") == true)
                            .commit()) { "전송 완료 상태 저장 실패" }
                        null
                    }
                    "deleteOriginals" -> {
                        if (!state.getBoolean("uploaded", false) ||
                            !state.getBoolean("deleteOriginals", false)) {
                            result.error("NOT_UPLOADED", "PC 전송 완료 확인 전에는 삭제할 수 없습니다.", null)
                        } else {
                            pending = result
                            try {
                                beginDeletion()
                            } catch (error: Exception) {
                                fail(error)
                            }
                        }
                    }
                    "discardPhotos" -> {
                        try {
                            check(!state.getBoolean("uploaded", false)) { "전송 완료 처리를 먼저 끝내세요." }
                            if (!state.contains("discardPaths")) {
                                val paths = call.argument<List<String>>("paths")?.toSet().orEmpty()
                                val known = records().map { it.getString("path") }.toSet()
                                check(paths.isNotEmpty() && known.containsAll(paths)) { "삭제할 선택 사진이 없습니다." }
                                check(state.edit().putString("discardPaths", JSONArray(paths.toList()).toString()).commit()) {
                                    "사진 삭제 대상 저장 실패"
                                }
                            }
                            pending = result
                            beginDeletion()
                        } catch (error: Exception) {
                            if (pending === result) fail(error)
                            else result.error("DISCARD_FAILED", error.message, null)
                        }
                    }
                    "finish" -> runWork(result) {
                        val items = records()
                        check(!state.getBoolean("deleteOriginals", false) ||
                            items.all { it.optBoolean("deleted") }) { "원본 삭제가 완료되지 않았습니다." }
                        check(state.edit().clear().commit()) { "선택 상태 초기화 실패" }
                        items.forEach { releasePhoto(it) }
                        File(cacheDir, "upload_prepared").listFiles()?.forEach { it.delete() }
                        null
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun records(): MutableList<JSONObject> {
        val array = JSONArray(state.getString("items", "[]"))
        return MutableList(array.length()) { array.getJSONObject(it) }
    }

    private fun save(items: List<JSONObject>) {
        check(state.edit().putString("items", JSONArray(items).toString()).commit()) {
            "원본 정보 저장 실패"
        }
    }

    private fun selection(): Map<String, Any> = mapOf(
        "photos" to records().map { item -> mapOf(
            "path" to item.getString("path"), "name" to item.getString("name"),
            "cropMonitor" to item.optBoolean("cropMonitor", true)) },
        "uploaded" to state.getBoolean("uploaded", false),
        "discardPending" to state.contains("discardPaths"),
        "deleteOriginals" to state.getBoolean("deleteOriginals", true)
    )

    private fun runWork(result: MethodChannel.Result, work: () -> Any?) {
        pending = result
        worker.execute {
            try {
                val value = work()
                runOnUiThread {
                    if (pending === result) pending = null
                    result.success(value)
                }
            } catch (error: Exception) {
                runOnUiThread {
                    if (pending === result) pending = null
                    result.error("ORIGINAL_PHOTO_ERROR", error.message ?: error.toString(), null)
                }
            }
        }
    }

    private fun succeed(value: Any?) {
        val result = pending
        pending = null
        result?.success(value)
    }

    private fun fail(error: Exception) {
        val result = pending
        pending = null
        // Partial explicit deletion must never leave deleted snapshots available
        // for an upload. Keep every original whose deletion was cancelled.
        try { cleanDiscarded(error is DeletionCancelled) } catch (cleanup: Exception) {
            result?.error("ORIGINAL_PHOTO_ERROR", "${error.message}; 목록 정리 실패: ${cleanup.message}", null)
            return
        }
        result?.error("ORIGINAL_PHOTO_ERROR", error.message ?: error.toString(), null)
    }

    private fun releasePhoto(item: JSONObject) {
        val source = File(item.getString("path"))
        UploadImageProcessor.forget(source, File(cacheDir, "upload_prepared"))
        source.delete()
        item.optString("captureSource").takeIf { it.isNotEmpty() }?.let { path ->
            val temporary = File(path).canonicalFile
            val roots = listOfNotNull(cacheDir, externalCacheDir, filesDir).map { it.canonicalPath + File.separator }
            if (roots.any { temporary.path.startsWith(it) }) temporary.delete()
        }
        try {
            contentResolver.releasePersistableUriPermission(Uri.parse(item.getString("uri")),
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        } catch (_: SecurityException) { /* URI already removed or owned by this app. */ }
    }

    private fun discardPaths(): Set<String>? = state.getString("discardPaths", null)?.let { saved ->
        val array = JSONArray(saved)
        (0 until array.length()).map { array.getString(it) }.toSet()
    }

    private fun cleanDiscarded(clearRequest: Boolean) {
        val paths = discardPaths() ?: return
        val items = records()
        val removed = items.filter { it.getString("path") in paths && it.optBoolean("deleted") }
        val retained = items.filterNot { it in removed }
        if (removed.isNotEmpty()) {
            save(retained)
            removed.forEach { releasePhoto(it) }
        }
        if (clearRequest || retained.none { it.getString("path") in paths }) {
            check(state.edit().remove("discardPaths").remove("pendingDelete").commit()) { "사진 삭제 상태 정리 실패" }
        }
        if (retained.isEmpty()) File(cacheDir, "upload_prepared").listFiles()?.forEach { it.delete() }
    }

    private fun deletionTargets(items: List<JSONObject>): List<JSONObject> {
        val paths = discardPaths()
        return items.filter { !it.optBoolean("deleted") && (paths == null || it.getString("path") in paths) }
    }

    private fun deletionComplete() {
        if (state.contains("discardPaths")) {
            cleanDiscarded(true)
            succeed(selection())
        } else succeed(null)
    }

    private fun deletionCancelled() = DeletionCancelled(if (state.contains("discardPaths"))
        "사진 삭제가 취소되었습니다. 삭제하지 않은 사진은 목록에 유지됩니다."
        else "원본 삭제가 취소되었습니다. PC 전송은 완료되었습니다.")

    private fun recoverCameraPhoto() {
        val saved = state.getString("cameraPending", null) ?: return
        val capture = JSONObject(saved)
        val uri = Uri.parse(capture.getString("uri"))
        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("이전 촬영 사진을 열 수 없습니다. 다시 시도하세요.")
        val hasBytes = input.use { it.read() != -1 }
        if (hasBytes) {
            acceptCameraPhoto(capture)
        } else {
            // Only an empty placeholder for our own aborted capture is removed.
            discardCameraPhoto()
        }
    }

    private fun importCameraPhoto(path: String, cropMonitor: Boolean = true) {
        // A lost channel reply must not create a duplicate photo on retry.
        if (records().any { it.optString("captureSource") == path }) {
            state.getString("cameraImport", null)?.let {
                val saved = JSONObject(it)
                saved.optString("uri").takeIf { value -> value.isNotEmpty() }?.let { value ->
                    acceptCameraPhoto(saved.put("uri", value))
                }
            }
            state.edit().remove("cameraImport").commit()
            return
        }
        val source = File(path).canonicalFile
        // String boundaries also work on Android 7; java.nio.file.Path requires
        // API 26 and would crash an otherwise supported API 24/25 device.
        val roots = listOfNotNull(cacheDir, externalCacheDir, filesDir).map { it.canonicalPath + File.separator }
        check(roots.any { source.path.startsWith(it) } && source.isFile && source.length() > 0) {
            "유효한 앱 촬영 파일이 아닙니다."
        }
        var capture = state.getString("cameraImport", null)?.let { JSONObject(it) }
        check(capture == null || capture.getString("path") == path) {
            "이전 사진 저장을 먼저 완료하세요."
        }
        if (capture == null) {
            val sequence = records().size + 1
            val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val name = "${stamp}_${String.format(Locale.US, "%03d", sequence)}.jpg"
            capture = JSONObject().put("path", path).put("name", name).put("cropMonitor", cropMonitor)
            check(state.edit().putString("cameraImport", capture.toString()).commit()) { "촬영 정보 저장 실패" }
        }
        val target = checkNotNull(capture)
        if (!target.has("uri")) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, target.getString("name"))
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                if (Build.VERSION.SDK_INT >= 29) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/PhotoUploader")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                } else {
                    val directory = File(Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_PICTURES), "PhotoUploader").apply { mkdirs() }
                    val name = target.getString("name")
                    var output = File(directory, name)
                    var counter = 1
                    while (output.exists()) output = File(directory, "${File(name).nameWithoutExtension}_${counter++}.jpg")
                    put(MediaStore.Images.Media.DATA, output.absolutePath)
                    put(MediaStore.Images.Media.DISPLAY_NAME, output.name)
                }
            }
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("촬영할 사진 저장 위치를 만들 수 없습니다.")
            target.put("uri", uri.toString())
            if (!state.edit().putString("cameraImport", target.toString()).commit()) {
                contentResolver.delete(uri, null, null)
                throw IllegalStateException("촬영 정보 저장 실패")
            }
        }
        val uri = Uri.parse(target.getString("uri"))
        val output = contentResolver.openOutputStream(uri, "wt")
            ?: throw IllegalStateException("촬영 원본을 저장할 수 없습니다.")
        output.use { destination -> source.inputStream().use { it.copyTo(destination) } }
        acceptCameraPhoto(target)
        check(state.edit().remove("cameraImport").commit()) { "촬영 완료 정보 저장 실패" }
        source.delete()
    }

    private fun discardCameraPhoto() {
        val capture = state.getString("cameraPending", null) ?: return
        val uri = Uri.parse(JSONObject(capture).getString("uri"))
        contentResolver.delete(uri, null, null)
        check(state.edit().remove("cameraPending").commit()) { "취소한 촬영 정보 정리 실패" }
    }

    private fun acceptCameraPhoto(capture: JSONObject) {
        val uri = Uri.parse(capture.getString("uri"))
        val items = records()
        if (items.none { it.getString("uri") == uri.toString() }) {
            val folder = File(filesDir, "selected_photos").apply { mkdirs() }
            val file = File(folder, UUID.randomUUID().toString())
            try {
                val input = contentResolver.openInputStream(uri)
                    ?: throw FileNotFoundException("촬영한 사진을 열 수 없습니다.")
                val size = input.use { source -> file.outputStream().use { source.copyTo(it) } }
                check(size > 0) { "카메라에서 사진 데이터를 저장하지 않았습니다." }
                items.add(JSONObject().put("uri", uri.toString())
                    .put("path", file.absolutePath).put("name", capture.getString("name"))
                    .put("captureSource", capture.optString("path"))
                    .put("kind", "camera").put("cropMonitor", capture.optBoolean("cropMonitor", true)).put("deleted", false))
                save(items)
            } catch (error: Exception) {
                file.delete()
                throw error
            }
        }
        if (Build.VERSION.SDK_INT >= 29) {
            contentResolver.update(uri, ContentValues().apply {
                put(MediaStore.Images.Media.IS_PENDING, 0)
            }, null, null)
        }
        state.getString("cameraPending", null)?.let {
            if (JSONObject(it).optString("uri") == uri.toString()) {
                check(state.edit().remove("cameraPending").commit()) { "촬영 완료 정보 저장 실패" }
            }
        }
    }

    @Deprecated("Uses the platform permission API for FlutterActivity compatibility")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_STORAGE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                succeed(null)
            } else fail(SecurityException("사진 저장 권한이 필요합니다. 갤러리 선택은 계속 사용할 수 있습니다."))
        }
    }

    @Deprecated("Uses the platform activity result API for FlutterActivity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            PICK -> {
                // Even if Android reclaimed the process while the picker was open,
                // persist its result so Dart's recover call can retrieve the URIs.
                if (resultCode != RESULT_OK || data == null) {
                    succeed(selection())
                    return
                }
                val uris = mutableListOf<Uri>()
                val clip = data.clipData
                if (clip != null) for (index in 0 until clip.itemCount) {
                    uris.add(clip.getItemAt(index).uri)
                } else data.data?.let { uris.add(it) }
                val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                // Copy off the UI thread. Save each URI immediately after copying.
                worker.execute {
                    try {
                        val items = records()
                        for (uri in uris.distinct()) {
                            if (items.any { it.getString("uri") == uri.toString() }) continue
                            contentResolver.takePersistableUriPermission(uri, flags)
                            val name = contentResolver.query(uri,
                                arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                                if (it.moveToFirst()) it.getString(0) else null
                            } ?: "photo.jpg"
                            val folder = File(filesDir, "selected_photos").apply { mkdirs() }
                            val file = File(folder, UUID.randomUUID().toString())
                            try {
                                val input = contentResolver.openInputStream(uri)
                                    ?: throw FileNotFoundException("사진을 열 수 없습니다: $name")
                                input.use { source -> file.outputStream().use { source.copyTo(it) } }
                                val item = JSONObject().put("uri", uri.toString())
                                    .put("path", file.absolutePath).put("name", name)
                                    .put("deleted", false)
                                items.add(item)
                                save(items)
                            } catch (error: Exception) {
                                file.delete()
                                throw error
                            }
                        }
                        val value = selection()
                        runOnUiThread { succeed(value) }
                    } catch (error: Exception) {
                        runOnUiThread { fail(error) }
                    }
                }
            }
            DELETE -> {
                if (resultCode != RESULT_OK) {
                    fail(deletionCancelled())
                    return
                }
                // createDeleteRequest performs the actual deletion after approval.
                try {
                    val items = records()
                    val batch = JSONArray(state.getString("pendingDelete", "[]"))
                    val deletedUris = (0 until batch.length()).map { batch.getString(it) }.toSet()
                    check(deletedUris.isNotEmpty()) { "삭제 승인 대상 정보가 없습니다. 원본 상태를 확인하세요." }
                    items.filter { it.getString("uri") in deletedUris }
                        .forEach { it.put("deleted", true) }
                    save(items)
                    check(state.edit().remove("pendingDelete").commit()) { "삭제 상태 저장 실패" }
                    if (pending == null && state.contains("discardPaths")) {
                        cleanDiscarded(false)
                        return // After process recovery, let the user resume remaining approvals.
                    }
                    beginDeletion()
                } catch (error: Exception) { fail(error) }
            }
            LEGACY_DELETE -> {
                if (resultCode != RESULT_OK) {
                    fail(deletionCancelled())
                } else {
                    // Android 10 grants permission; unlike Android 11+, retry delete.
                    deleteDocuments()
                }
            }
        }
    }

    private fun mediaUri(item: JSONObject): Uri? {
        if (Build.VERSION.SDK_INT < 30) return null
        val uri = Uri.parse(item.getString("uri"))
        if (uri.authority == MediaStore.AUTHORITY) return uri
        return try { MediaStore.getMediaUri(this, uri) } catch (_: Exception) { null }
    }

    private fun beginDeletion() {
        val remaining = deletionTargets(records())
        if (remaining.isEmpty()) {
            deletionComplete()
            return
        }
        if (Build.VERSION.SDK_INT >= 30) {
            // Only URI conversion supplied by Android is used; never match names,
            // timestamps, or file sizes to guess which original to remove.
            val media = remaining.mapNotNull { item -> mediaUri(item)?.let { item to it } }
                .take(200) // Stay below the platform's batch URI limit.
            if (media.isNotEmpty()) {
                val request = MediaStore.createDeleteRequest(contentResolver, media.map { it.second })
                check(state.edit().putString("pendingDelete",
                    JSONArray(media.map { it.first.getString("uri") }).toString()).commit()) {
                    "삭제 승인 대상 저장 실패"
                }
                startIntentSenderForResult(request.intentSender, DELETE, null, 0, 0, 0)
                return
            }
        }
        // SAF providers and older Android releases delete the selected document
        // itself. Confirm the irreversible operation before invoking the provider.
        AlertDialog.Builder(this)
            .setTitle(if (state.contains("discardPaths")) "선택 사진 삭제" else "전송한 원본 사진 삭제")
            .setMessage(if (state.contains("discardPaths")) "PC로 보내지 않고 사진 ${remaining.size}장의 기기 원본을 영구 삭제할까요?"
                else "PC에 저장된 사진 ${remaining.size}장의 기기 원본을 영구 삭제할까요?")
            .setPositiveButton("원본 삭제") { _, _ -> deleteDocuments() }
            .setNegativeButton("취소") { _, _ ->
                fail(deletionCancelled()) }
            .setOnCancelListener {
                fail(deletionCancelled()) }
            .show()
    }

    private fun deleteDocuments() {
        worker.execute {
            try {
                val items = records()
                for (item in deletionTargets(items)) {
                    legacyItem = item
                    val uri = Uri.parse(item.getString("uri"))
                    try {
                        val deleted = if (item.optString("kind") == "camera") {
                            contentResolver.delete(uri, null, null) > 0
                        } else DocumentsContract.deleteDocument(contentResolver, uri)
                        check(deleted) {
                            "이 사진 제공자가 원본 삭제를 지원하지 않습니다: ${item.getString("name")}"
                        }
                    } catch (error: FileNotFoundException) {
                        // A previous deletion can finish just before process death.
                        // Only explicit provider 'not found' is treated as already gone.
                        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME),
                            null, null, null)?.use { cursor ->
                            if (cursor.moveToFirst()) throw error
                        } ?: throw error
                    }
                    item.put("deleted", true)
                    save(items)
                    legacyItem = null
                }
                runOnUiThread {
                    try { deletionComplete() } catch (error: Exception) { fail(error) }
                }
            } catch (error: Exception) {
                if (Build.VERSION.SDK_INT == 29 && error is RecoverableSecurityException) {
                    runOnUiThread {
                        try {
                            startIntentSenderForResult(error.userAction.actionIntent.intentSender,
                                LEGACY_DELETE, null, 0, 0, 0)
                        } catch (launchError: Exception) { fail(launchError) }
                    }
                } else {
                    runOnUiThread { fail(IllegalStateException(
                        "원본 삭제 실패 (${legacyItem?.optString("name") ?: "사진"}): ${error.message}", error)) }
                }
            }
        }
    }
}
