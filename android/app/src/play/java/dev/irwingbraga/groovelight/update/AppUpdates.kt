package dev.irwingbraga.groovelight.update

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Google Play updates the app: this build never checks or installs anything itself. */
object AppUpdates {
    const val SUPPORTED = false
    val state: StateFlow<UpdateState> = MutableStateFlow(UpdateState.Idle)
    val dismissed: StateFlow<String?> = MutableStateFlow(null)

    fun checkIfDue(context: Context) = Unit
    fun check(context: Context) = Unit
    fun install(context: Context) = Unit
    fun dismiss(context: Context, version: String) = Unit
}
