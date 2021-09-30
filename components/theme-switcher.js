import Image from 'next/image'
import LightIcon from '../img/theme_light.png'
import DarkIcon from '../img/theme_dark.png'
import { useTheme } from 'next-themes'
import { useState, useEffect } from 'react'

export default function ThemeSwitcher() {
  const [mounted, setMounted] = useState(false)
  const { theme, setTheme } = useTheme()
  // When mounted on client, now we can show the UI
  useEffect(() => setMounted(true), [])
  const themeToggler = () => {
    theme === 'dark' ? setTheme('light') : setTheme('dark')
  }
  if (!mounted) return null
  return (
    <div className="theme_switcher">
      <button className="theme_switcher_btn" onClick={() => themeToggler()}>
        <Image alt="Change theme" src={theme === 'dark' ? LightIcon : DarkIcon} width={30} height={30} />
      </button>
    </div>
  )
}
