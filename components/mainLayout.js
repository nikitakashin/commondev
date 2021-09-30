import NavigationBar from '../components/navigationBar'
import SideBar from '../components/sideBar'
import Footer from '../components/footer'
import React from 'react'

export function MainLayout({children}) {
    return (
        <>
            <nav>
                <NavigationBar/>
            </nav>
            <SideBar/>
            <main>
                {children}
            </main>
            <footer>
                <Footer/>
            </footer>
        </>
    )
}