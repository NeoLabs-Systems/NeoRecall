'use strict';

const nav = document.querySelector('nav');
const progress = document.querySelector('.progress-bar');
const reveal = new IntersectionObserver((entries) => {
  for (const entry of entries) if (entry.isIntersecting) entry.target.classList.add('is-visible');
}, { threshold: 0.12 });
document.querySelectorAll('.reveal').forEach((element) => reveal.observe(element));
function updateScroll() {
  const maximum = document.documentElement.scrollHeight - innerHeight;
  nav.classList.toggle('scrolled', scrollY > 8);
  progress.style.width = `${maximum > 0 ? Math.min(100, scrollY / maximum * 100) : 0}%`;
}
addEventListener('scroll', updateScroll, { passive: true });
updateScroll();
