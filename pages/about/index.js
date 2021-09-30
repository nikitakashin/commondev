import Link from 'next/link'
import { useRouter } from 'next/router'
import { MainLayout } from '../../components/mainLayout'

export default function IndexPage(props) {
  const router = useRouter()
  const { locale, locales, defaultLocale } = router

  return (
    <MainLayout>
        <h1>About page</h1>
        <Link href="/team"><a>Команда</a></Link>
    </MainLayout>
  )
}