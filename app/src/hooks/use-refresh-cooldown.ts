'use client'

import { useState, useEffect } from 'react'
import { formatAge } from '@/lib/format'

const COOLDOWN_MS = 30_000

export function useRefreshCooldown() {
  const [cooldownUntil, setCooldownUntil] = useState(0)
  const [lastRefreshedAt, setLastRefreshedAt] = useState(() => Date.now())
  const [now, setNow] = useState(() => Date.now())

  const onCooldown = now < cooldownUntil

  // Tick every second while on cooldown (for the countdown display),
  // every 60 s otherwise (to keep "last refreshed X ago" fresh).
  useEffect(() => {
    const ms = onCooldown ? 1_000 : 60_000
    const id = setInterval(() => setNow(Date.now()), ms)
    return () => clearInterval(id)
  }, [onCooldown])

  const canRefresh = now >= cooldownUntil
  const secondsLeft = canRefresh ? 0 : Math.ceil((cooldownUntil - now) / 1000)
  const lastRefreshedLabel = formatAge(BigInt(Math.floor(lastRefreshedAt / 1000)))

  function startCooldown() {
    const t = Date.now()
    setCooldownUntil(t + COOLDOWN_MS)
    setLastRefreshedAt(t)
    setNow(t)
  }

  return { canRefresh, secondsLeft, startCooldown, lastRefreshedLabel }
}
