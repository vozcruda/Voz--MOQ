import { createRoot } from 'react-dom/client'
import App from './App'
import './styles.css'
createRoot(document.getElementById('root')!).render(<App />)

// Lets phones install Smallotz as an app (Chrome: "Install app", iPhone: "Add to Home Screen")
if ('serviceWorker' in navigator && location.protocol === 'https:') {
  window.addEventListener('load', () => { navigator.serviceWorker.register('/sw.js').catch(() => {}) })
}
