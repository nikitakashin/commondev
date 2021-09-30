import Link from 'next/link'
import { useRouter } from 'next/router'
import Image from 'next/image'
import LightIcon from '../img/lang_light.png'
import DarkIcon from '../img/lang_dark.png'
import { useTheme } from 'next-themes'

export default function LocaleSwitcher() {
  const router = useRouter()
  const { locales, locale: activeLocale } = router
  const otherLocales = locales.filter((locale) => locale !== activeLocale)
  const { theme } = useTheme()
  
  const openSwicher = () => {
    const icon = document.querySelector('#swicher')
    icon.style.display = 'block'
    console.log(icon.offsetWidth);
  }

  return (
    <>

    </>
  )
}
