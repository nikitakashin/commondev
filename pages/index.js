import Link from 'next/link'
import { useRouter } from 'next/router'
import { MainLayout } from '../components/mainLayout'
import useTranslation from 'next-translate/useTranslation'

export default function IndexPage(props) {
  const router = useRouter()
  const { locale, locales, defaultLocale } = router
  let { t } = useTranslation()
  return (
    <MainLayout>
      <h1>{t('common:greeting')}</h1>
      <p>Current locale: {locale}</p>
      <p>Default locale: {defaultLocale}</p>
      <p>Configured locales: {JSON.stringify(locales)}</p>

      <Link href="/about">
        <a>To about page</a>
      </Link>
      <h1>заполнитель</h1><br/>
      <h1>заполнитель</h1><br/>
      <h1>заполнитель</h1><br/>
      <h1>заполнитель</h1><br/>

    </MainLayout>
  )
}


// font-family: 'Roboto', sans-serif;
// font-family: 'Rancho', cursive;