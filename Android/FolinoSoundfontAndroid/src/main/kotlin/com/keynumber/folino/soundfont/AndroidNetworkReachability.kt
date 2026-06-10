package com.keynumber.folino.soundfont

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest

/**
 * Kotlin implementation of the generated `@WireletProvided` `SoundfontReachability` interface over
 * `ConnectivityManager`. `isWiFi` is a synchronous snapshot; `startObserving` registers a callback that pushes
 * Wi-Fi transitions back into the Swift store via [onReachabilityChanged].
 *
 * @param onReachabilityChanged invoked with the new Wi-Fi state on every transition. Wired to the generated
 *   ViewModel's `onReachabilityChanged(isWiFi:)` at construction.
 */
class AndroidNetworkReachability(
    context: Context,
    private val onReachabilityChanged: (Boolean) -> Unit,
) : SoundfontReachability {
    private val cm =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun isWiFi(): Boolean {
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    override fun startObserving() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = onReachabilityChanged(isWiFi())
            override fun onLost(network: Network) = onReachabilityChanged(isWiFi())
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                onReachabilityChanged(isWiFi())
        })
    }
}
