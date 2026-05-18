'use client'

import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { type ReactNode, useState } from 'react'
import { http, createConfig, WagmiProvider } from 'wagmi'
import { arbitrum, base, gnosis, mainnet, optimism } from 'wagmi/chains'

function makeWagmiConfig() {
  return createConfig({
    chains: [mainnet, optimism, gnosis, arbitrum, base],
    ssr: true,
    transports: {
      [mainnet.id]: http(process.env.NEXT_PUBLIC_RPC_URL_1 || undefined),
      [optimism.id]: http(process.env.NEXT_PUBLIC_RPC_URL_10 || undefined),
      [gnosis.id]: http(process.env.NEXT_PUBLIC_RPC_URL_100 || undefined),
      [arbitrum.id]: http(process.env.NEXT_PUBLIC_RPC_URL_42161 || undefined),
      [base.id]: http(process.env.NEXT_PUBLIC_RPC_URL_8453 || undefined),
    },
  })
}

export function Providers({ children }: { children: ReactNode }) {
  const [config] = useState(() => makeWagmiConfig())
  const [queryClient] = useState(() => new QueryClient())

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  )
}
