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
          <div className="min-h-screen flex flex-col">
            <header className="border-b bg-background">
              <div className="max-w-7xl mx-auto px-4 py-4 flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <span className="font-bold text-lg">NAV Dashboard</span>
                  <span className="text-xs text-muted-foreground bg-muted px-2 py-0.5 rounded">
                    prototype
                  </span>
                </div>
                <nav className="flex gap-6 text-sm">
                  <a href="/" className="hover:text-primary transition-colors">Portfolio</a>
                  <a href="/feeds" className="hover:text-primary transition-colors">Price Feeds</a>
                </nav>
              </div>
            </header>
            <main className="flex-1 max-w-7xl mx-auto px-4 py-8 w-full">
              {children}
            </main>
            <footer className="border-t py-4 text-center text-xs text-muted-foreground">
              karpatkey · read-only · prototype
            </footer>
          </div>
          <Toaster />
        </Providers>
      </body>
    </html>
  )
}
