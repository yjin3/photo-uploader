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
    companion object {
        private const val CHANNEL = "photo_uploader/originals"
        private const val PICK = 4101
        private const val DELETE = 4102
        private const val LEGACY_DELETE = 4103
        private const val CAMERA_STORAGE = 4105
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val state by lazy { getSharedPreferences("original_photos", MODE_PRIVATE) }
    private var pending: MethodChannel.Result? = null
    private var legacyItem: JSONObject? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (pending != null) {
                    result.error("BUSY", "다른 사진 작업을 처리 중입니다.", null)
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
                            else runWork(result) { importCameraPhoto(path); selection() }
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
                    "finish" -> runWork(result) {
                        val items = records()
                        check(!state.getBoolean("deleteOriginals", false) ||
                            items.all { it.optBoolean("deleted") }) { "원본 삭제가 완료되지 않았습니다." }
                        check(state.edit().clear().commit()) { "선택 상태 초기화 실패" }
                        for (item in items) {
                            File(item.getString("path")).delete()
                            try {
                                contentResolver.releasePersistableUriPermission(
                                    Uri.parse(item.getString("uri")),
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                            } catch (_: SecurityException) { /* URI already removed. */ }
                        }
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
            "path" to item.getString("path"), "name" to item.getString("name")) },
        "uploaded" to state.getBoolean("uploaded", false),
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
        result?.error("ORIGINAL_PHOTO_ERROR", error.message ?: error.toString(), null)
    }

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

    private fun importCameraPhoto(path: String) {
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
            capture = JSONObject().put("path", path).put("name", name)
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
                    .put("kind", "camera").put("deleted", false))
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
                    fail(IllegalStateException("원본 삭제가 취소되었습니다. PC 전송은 완료되었습니다."))
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
                    beginDeletion()
                } catch (error: Exception) { fail(error) }
            }
            LEGACY_DELETE -> {
                if (resultCode != RESULT_OK) {
                    fail(IllegalStateException("원본 삭제 승인이 취소되었습니다."))
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
        val remaining = records().filter { !it.optBoolean("deleted") }
        if (remaining.isEmpty()) {
            succeed(null)
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
            .setTitle("전송한 원본 사진 삭제")
            .setMessage("PC에 저장된 사진 ${remaining.size}장의 기기 원본을 영구 삭제할까요?")
            .setPositiveButton("원본 삭제") { _, _ -> deleteDocuments() }
            .setNegativeButton("취소") { _, _ ->
                fail(IllegalStateException("원본 삭제가 취소되었습니다. PC 전송은 완료되었습니다.")) }
            .setOnCancelListener {
                fail(IllegalStateException("원본 삭제가 취소되었습니다. PC 전송은 완료되었습니다.")) }
            .show()
    }

    private fun deleteDocuments() {
        worker.execute {
            try {
                val items = records()
                for (item in items.filter { !it.optBoolean("deleted") }) {
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
                runOnUiThread { succeed(null) }
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
