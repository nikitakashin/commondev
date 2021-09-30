import { ThemeProvider } from 'next-themes'
import { MainLayout } from '../components/mainLayout'

export default function Custom404() {
    return (
        
        <ThemeProvider enableSystem={true} attribute="class">
            <MainLayout>
                <div className="errorContainer">
                    <div>
                        <h1 className="errorHeader">404</h1>
                        <div className="errorBody">
                            <h2 className="errorText">This page could not be found.</h2>
                        </div>
                    </div>
                </div>
            </MainLayout>
        </ThemeProvider>

    )
}