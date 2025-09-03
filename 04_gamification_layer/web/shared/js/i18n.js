/* Lightweight i18n helper shared across frameworks */
(function(){
  const I18N = {
    lang: 'en',
    messages: {},
    base: (window.APP_SHARED_BASE || './shared'),
    async load(lang){
      this.lang = lang || this.lang;
      const url = `${this.base}/i18n/${this.lang}.json`;
      const res = await fetch(url);
      this.messages = await res.json();
      this.apply();
      localStorage.setItem('lang', this.lang);
    },
    t(key){
      return key.split('.').reduce((o, k) => (o && o[k] !== undefined) ? o[k] : key, this.messages);
    },
    apply(){
      document.querySelectorAll('[data-i18n]').forEach(el => {
        const key = el.getAttribute('data-i18n');
        el.textContent = this.t(key);
      });
    }
  };
  window.I18N = I18N;
})();
