import Link from 'next/link'
import { ShortUrlLayout } from '../components/shortUrlLayout'

export default function IndexPage(props) {

  return (
    <ShortUrlLayout>
      <h1>URL Shortener page.</h1>
      <h4>In development...</h4>

      <Link href="/">
        <a>Back to commondev_</a>
      </Link>

    </ShortUrlLayout>
  )
}
