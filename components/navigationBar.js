import { Component } from 'react';
import Link from 'next/link'
import LocaleSwitcher from '../components/locale-switcher'
import ThemeSwitcher from '../components/theme-switcher'
import MainMenu from './mainMenu';

export default class NavigationBar extends Component {
    render() {
        return (
            <div className="header">
                <div className="logo">
                    <Link href="../"><a className="navbar-brand">
                        <kok className="common">common</kok><kok className="dev">dev</kok><kok className="defis" id="defis">_</kok>
                    </a></Link>
                </div>
                <div className="upper_nav_menu">
                    <MainMenu/>
                </div>
                <div className="swichers">
                    <LocaleSwitcher />
                    <ThemeSwitcher />
                </div>
            </div>
        );
    }
}
