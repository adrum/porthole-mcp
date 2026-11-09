package dev.porthole

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri

/**
 * Starts Porthole when the app launches. Android creates every manifest
 * ContentProvider before Application.onCreate, so adding the library as a
 * `debugImplementation` dependency is all an app does: release builds don't
 * contain this provider at all.
 */
class PortholeInitializer : ContentProvider() {
    override fun onCreate(): Boolean {
        context?.let { Porthole.start(it) }
        return true
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
