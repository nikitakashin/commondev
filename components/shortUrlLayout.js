import { Head } from 'next/head'
import Link from 'next/link'
export function ShortUrlLayout({children}) {
    return (
        <>
        <Head>
            {/* <link rel="preconnect" href="https://fonts.googleapis.com"></link>
            <link href="https://fonts.googleapis.com/css2?family=Rancho&display=swap" rel="stylesheet"></link>
            <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin></link> */}
        </Head>
            <nav>
                <div className="header">
                    <div className="logo">
                        commondev_
                    </div>
                    <div className="upper_nav_menu">
                        <Link href="/"><a>Главная</a></Link>
                        <Link href="/about"><a>О нас</a></Link>
                    </div>
                </div>
            </nav>
            <main>
                {children}
            </main>
        </>
    )
}