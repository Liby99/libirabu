import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono, Caveat } from "next/font/google";
import "./globals.css";
import "./dashboard.css";
import { Providers } from "./providers";
import ActivityBar from "./components/app/ActivityBar";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

// Hand-writing-like font for calendar event titles.
const caveat = Caveat({
  variable: "--font-handwriting",
  subsets: ["latin"],
  weight: ["500", "600", "700"],
});

export const metadata: Metadata = {
  title: "libirabu",
  description: "Research-group dashboard: calendar, projects, people, papers, proposals, funding, and AI assistant",
  keywords: "yearly planner, goal tracking, calendar, productivity, planning tool",
  authors: [{ name: "Liby99" }],
  creator: "Liby99",
  publisher: "Liby99",
  formatDetection: {
    email: false,
    address: false,
    telephone: false,
  },
  metadataBase: new URL('https://yearly-tracker.vercel.app'),
  openGraph: {
    title: "Yearly Tracker",
    description: "A comprehensive yearly planning and tracking tool for organizing your goals, events, and notes throughout the year",
    type: "website",
    locale: "en_US",
  },
  twitter: {
    card: "summary_large_image",
    title: "Yearly Tracker",
    description: "A comprehensive yearly planning and tracking tool",
  },
  robots: {
    index: true,
    follow: true,
  },
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "Yearly Tracker",
  },
  manifest: "/manifest.json",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 5,
  userScalable: true,
  viewportFit: "cover",
  themeColor: "#ffffff",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <head>
        <meta name="mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-status-bar-style" content="default" />
        <meta name="apple-mobile-web-app-title" content="Yearly Tracker" />
        <meta name="msapplication-TileColor" content="#ffffff" />
        <meta name="msapplication-config" content="/browserconfig.xml" />
        <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
        <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png" />
        <link rel="icon" type="image/png" sizes="16x16" href="/favicon-16x16.png" />
        <link rel="manifest" href="/manifest.json" />
      </head>
      <body
        className={`${geistSans.variable} ${geistMono.variable} ${caveat.variable} antialiased`}
      >
        <Providers>
          <div className="app-shell">
            <ActivityBar />
            <div className="app-body">{children}</div>
          </div>
        </Providers>
      </body>
    </html>
  );
}
