const { createApp } = Vue;

function get(key, obj){
  return key.split('.').reduce((o,k)=> (o && o[k]!==undefined) ? o[k] : key, obj);
}

createApp({
  data(){
    return {
      lang: localStorage.getItem('lang') || 'en',
      skin: localStorage.getItem('skin') || 'classic',
      messages: {}
    }
  },
  computed: {
    t(){ return (k)=> get(k, this.messages); }
  },
  methods: {
    async loadI18n(){
      const base = '../../../shared';
      const res = await fetch(`${base}/i18n/${this.lang}.json`);
      this.messages = await res.json();
      localStorage.setItem('lang', this.lang);
    },
    applySkin(){
      SKIN.set(this.skin);
    }
  },
  async mounted(){
    window.APP_SHARED_BASE = '../../../shared';
    await this.loadI18n();
    SKIN.init(this.skin);
  }
}).mount('#app');
