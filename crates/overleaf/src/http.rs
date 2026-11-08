//! Overleaf's web app over HTTP: login, the CSRF token, the project list.

use crate::Error;
use reqwest::cookie::{CookieStore, Jar};
use serde::Deserialize;
use serde_json::Value;
use std::sync::Arc;
use url::Url;

/// An HTTP session with one Overleaf server. Cookies persist across calls.
#[derive(Clone)]
pub struct Http {
    pub client: reqwest::Client,
    pub base: Url,
    jar: Arc<Jar>,
    pub csrf: Option<String>,
    /// The logged-in user's ID and email, from the `ol-user_id` and `ol-usersEmail` meta tags of the last page read.
    pub user_id: Option<String>,
    pub email: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProjectSummary {
    #[serde(rename = "_id")]
    pub id: String,
    pub name: String,
    #[serde(flatten)]
    pub rest: serde_json::Map<String, Value>,
}

impl Http {
    pub fn new(base: &str) -> Result<Http, Error> {
        let mut base = Url::parse(base)?;
        if !base.path().ends_with('/') {
            base.set_path(&format!("{}/", base.path()));
        }
        let jar = Arc::new(Jar::default());
        let client = reqwest::Client::builder()
            .cookie_provider(jar.clone())
            .user_agent(concat!("taudot/", env!("CARGO_PKG_VERSION")))
            // A half-open network must not hang a caller forever (the project actor awaits these). No total timeout:
            // a big download may take long, but not with the connection silent for a minute.
            .connect_timeout(std::time::Duration::from_secs(15))
            .read_timeout(std::time::Duration::from_secs(60))
            .build()?;
        Ok(Http { client, base, jar, csrf: None, user_id: None, email: None })
    }

    /// Use an existing session cookie, such as one copied from a browser (`overleaf_session2=...`).
    pub fn with_cookie(base: &str, cookie: &str) -> Result<Http, Error> {
        let http = Http::new(base)?;
        for part in cookie.split(';') {
            let part = part.trim();
            if !part.is_empty() {
                http.jar.add_cookie_str(part, &http.base);
            }
        }
        Ok(http)
    }

    /// The `Cookie` header this session sends to the server.
    pub fn cookie_header(&self) -> Option<String> {
        self.jar.cookies(&self.base).and_then(|h| h.to_str().ok().map(String::from))
    }

    /// Fetch a page and read its `ol-csrfToken` meta tag.
    pub async fn fetch_csrf(&mut self, path: &str) -> Result<String, Error> {
        let resp = self.client.get(self.base.join(path)?).send().await?;
        let status = resp.status();
        let html = resp.text().await?;
        if !status.is_success() {
            return Err(Error::Http(format!("GET {path}: {status}")));
        }
        let token = meta_content(&html, "ol-csrfToken")
            .ok_or_else(|| Error::Http(format!("GET {path}: no ol-csrfToken on the page")))?;
        self.csrf = Some(token.clone());
        if let Some(id) = meta_content(&html, "ol-user_id").filter(|s| !s.is_empty()) {
            self.user_id = Some(id);
        }
        if let Some(e) = meta_content(&html, "ol-usersEmail").filter(|s| !s.is_empty()) {
            self.email = Some(e);
        }
        Ok(token)
    }

    /// Log in with email and password, as the login form does
    /// (`POST /login`, `services/web/app/src/Features/Authentication/AuthenticationController.mjs`).
    pub async fn login(&mut self, email: &str, password: &str) -> Result<(), Error> {
        let csrf = self.fetch_csrf("login").await?;
        let resp = self
            .client
            .post(self.base.join("login")?)
            .header(reqwest::header::ACCEPT, "application/json")
            .json(&serde_json::json!({ "email": email, "password": password, "_csrf": csrf }))
            .send()
            .await?;
        let status = resp.status();
        let body: Value = resp.json().await.unwrap_or(Value::Null);
        if !status.is_success() || body.get("redir").is_none() {
            let msg = body
                .pointer("/message/text")
                .and_then(Value::as_str)
                .map(String::from)
                .unwrap_or_else(|| body.to_string());
            return Err(Error::Login(format!("{status}: {msg}")));
        }
        // Login regenerates the session, so the CSRF token changes too.
        self.fetch_csrf("project").await?;
        Ok(())
    }

    /// The logged-in user's projects (`GET /user/projects`).
    pub async fn projects(&self) -> Result<Vec<ProjectSummary>, Error> {
        let resp = self
            .client
            .get(self.base.join("user/projects")?)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await?;
        let status = resp.status();
        if !status.is_success() {
            return Err(Error::Http(format!("GET /user/projects: {status}")));
        }
        #[derive(Deserialize)]
        struct R {
            projects: Vec<ProjectSummary>,
        }
        let r: R = resp.json().await?;
        Ok(r.projects)
    }
}

/// The `content` of `<meta name="NAME" content="...">`, in either attribute order.
pub(crate) fn meta_content(html: &str, name: &str) -> Option<String> {
    let needle = format!("name=\"{name}\"");
    let at = html.find(&needle)?;
    let start = html[..at].rfind('<')?;
    let end = at + html[at..].find('>')?;
    let tag = &html[start..end];
    let c = tag.find("content=\"")? + "content=\"".len();
    let len = tag[c..].find('"')?;
    Some(html_unescape(&tag[c..c + len]))
}

fn html_unescape(s: &str) -> String {
    s.replace("&quot;", "\"").replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_meta_tag() {
        let html = r#"<head><meta name="ol-foo" content="x"><meta name="ol-csrfToken" content="abC-12_3"></head>"#;
        assert_eq!(meta_content(html, "ol-csrfToken").as_deref(), Some("abC-12_3"));
        let html = r#"<meta content="tok&amp;en" name="ol-csrfToken"/>"#;
        assert_eq!(meta_content(html, "ol-csrfToken").as_deref(), Some("tok&en"));
        assert_eq!(meta_content(html, "ol-other"), None);
    }

    #[test]
    fn cookie_header_from_given_cookie() {
        let h = Http::with_cookie("http://localhost:8800", "overleaf_session2=s%3Aabc.def").unwrap();
        assert_eq!(h.cookie_header().as_deref(), Some("overleaf_session2=s%3Aabc.def"));
    }
}
