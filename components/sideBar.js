import Image from 'next/image'
import { Component } from 'react';
import MainMenu from './mainMenu';

export default class SideBar extends Component {
    render() {
        return (
            <div className="sidebar_container">
                <div className="sidebar">
                    <div className="sidebar_body">
                        <MainMenu/>
                    </div>
                    <div className="left_corner"></div>
                    <div className="right_corner"></div>
                </div>
            </div>
        )
    }
}
