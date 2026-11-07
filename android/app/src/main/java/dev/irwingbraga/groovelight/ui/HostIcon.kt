package dev.irwingbraga.groovelight.ui

import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.sync.Host

/** The paired computer's icon: a desktop PC for Groovelight for Windows, the laptop for a Mac. */
val hostIcon: Int get() = if (Host.isWindows) R.drawable.ic_desktop else R.drawable.ic_laptop
