import { Component } from 'react';
import Link from 'next/link'
import useTranslation from 'next-translate/useTranslation'

export default function MainMenu() {
    const { t } = useTranslation()
    return (
        <ul>
            <li><Link href="/"><a>{t('common:main_page')}</a></Link></li>
            <li><Link href="/articles"><a>{t('common:articles_page')}</a></Link></li>
            <li><Link href="/products"><a>{t('common:products_page')}</a></Link></li>
            <li><Link href="/about"><a>{t('common:about_page')}</a></Link></li>
            <li><Link href="/contacts"><a>{t('common:contacts_page')}</a></Link></li>
        </ul>
    )
}
