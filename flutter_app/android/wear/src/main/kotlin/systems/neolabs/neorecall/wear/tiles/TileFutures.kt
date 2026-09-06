package systems.neolabs.neorecall.wear.tiles

import androidx.concurrent.futures.ResolvableFuture
import com.google.common.util.concurrent.ListenableFuture

/**
 * Both tiles are built synchronously from a preference read, so neither has
 * anything to wait for. This keeps that fact in one place rather than pulling
 * in a futures library to express "already done".
 */
internal fun <T> immediateFuture(value: T): ListenableFuture<T> =
  ResolvableFuture.create<T>().apply { set(value) }
