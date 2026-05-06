import type { Metadata } from 'next'
import { Providers } from '@/lib/providers'
import { Toaster } from '@karpatkey/design-system'
import './globals.css'

export const metadata: Metadata = {
  title: 'NAV Dashboard',
  description: 'On-chain NAV and price feed monitor for karpatkey portfolios',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          {children}
          <Toaster />
        </Providers>
      </body>
    </html>
  )
}
