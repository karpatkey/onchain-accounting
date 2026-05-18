'use client'

import { useState } from 'react'
import { isAddress } from 'viem'
import { Button } from '@karpatkey/design-system'
import { Input } from '@karpatkey/design-system'

interface AddressInputProps {
  onSearch: (address: `0x${string}`) => void
  isLoading?: boolean
}

export function AddressInput({ onSearch, isLoading }: AddressInputProps) {
  const [value, setValue] = useState('')
  const [error, setError] = useState('')

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    const trimmed = value.trim()
    if (!isAddress(trimmed)) {
      setError('Enter a valid Ethereum address')
      return
    }
    setError('')
    onSearch(trimmed as `0x${string}`)
  }

  return (
    <form onSubmit={handleSubmit} className="flex gap-3 items-start">
      <div className="flex-1">
        <Input
          placeholder="0x…"
          value={value}
          onChange={(e) => {
            setValue(e.target.value)
            if (error) setError('')
          }}
          className="font-mono"
          aria-label="Account address"
        />
        {error && <p className="text-red-500 text-sm mt-1">{error}</p>}
      </div>
      <Button type="submit" disabled={isLoading}>
        {isLoading ? 'Loading…' : 'Query NAV'}
      </Button>
    </form>
  )
}
