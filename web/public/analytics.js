// Website analytics: PostHog in cookieless mode.
//
// Before this, the only traffic record was Fly's nginx logs, which roll off
// after about six days. This sends pageviews and clicks (autocapture, which
// is how App Store badge taps show up) to the same PostHog project as the
// app. Split web from app at query time with $lib = 'web'.
//
// cookieless_mode 'always': no cookies, no localStorage, no sessionStorage.
// PostHog counts unique visitors with a daily-rotating server-side hash
// instead, so the site needs no cookie banner. This only works while the
// project setting "cookieless server hash mode" is on; with it off, PostHog
// silently drops these events.
//
// Session replay stays off here. The project has replay enabled for the app,
// and the web SDK would otherwise pick that up.
//
// The block below is PostHog's standard loader snippet, verbatim
// (posthog.com/docs/libraries/js). It defines a stub that queues calls and
// loads the real SDK from us-assets.i.posthog.com.
!function(t,e){var o,n,p,r;e.__SV||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host.replace(".i.posthog.com","-assets.i.posthog.com")+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],Object.defineProperty(u,"toString",{configurable:!0,enumerable:!0,writable:!0,value:function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e}}),Object.defineProperty(u.people,"toString",{configurable:!0,enumerable:!0,writable:!0,value:function(){return u.toString(1)+".people (stub)"}}),o="init capture register register_once register_for_session unregister unregister_for_session getFeatureFlag getFeatureFlagResult isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey getNextSurveyStep identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty createPersonProfile opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing debug".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);

// Production only. Every web PR deploys to tailspot-www-preview.fly.dev, and
// local checks serve this folder on localhost; both would otherwise count as
// visits in the real project.
if (location.hostname === 'tailspot.app' || location.hostname === 'www.tailspot.app') {
  // The project token is public by design: it can only write events, and
  // every web page that uses PostHog ships its token in the HTML.
  posthog.init('phc_me4LnpPccwc3NiaaNho5BM7bkJQ99UZpkvVjkHUC4Eih', {
    api_host: 'https://us.i.posthog.com',
    defaults: '2026-08-30',
    cookieless_mode: 'always',
    // The project turns these on for the app. Off here so the site collects
    // only what the privacy policy's "This website" paragraph lists, and
    // loads no extra SDK bundles.
    disable_session_recording: true,
    capture_heatmaps: false,
    capture_dead_clicks: false,
    capture_performance: false
  });
}
