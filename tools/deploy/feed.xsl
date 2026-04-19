<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:atom="http://www.w3.org/2005/Atom">
  <xsl:output method="html" encoding="UTF-8" indent="yes"
    doctype-system="about:legacy-compat"/>

  <xsl:template match="/atom:feed">
    <html lang="en">
      <head>
        <meta charset="UTF-8"/>
        <meta name="viewport" content="width=device-width,initial-scale=1.0"/>
        <title><xsl:value-of select="atom:title"/> — releases</title>
        <link rel="stylesheet" href="/feed.css"/>
      </head>
      <body>
        <header>
          <h1><xsl:value-of select="atom:title"/> · releases</h1>
          <p><xsl:value-of select="atom:subtitle"/></p>
          <div class="feed-note">
            This is an Atom feed. Paste the URL (<code>/feed.xml</code>) into any feed reader to subscribe.
            Source: <a href="https://github.com/zemo-g/rail/blob/next/CHANGELOG.md">CHANGELOG.md</a>
          </div>
        </header>

        <xsl:for-each select="atom:entry">
          <article>
            <h2>
              <a>
                <xsl:attribute name="href"><xsl:value-of select="atom:link/@href"/></xsl:attribute>
                <xsl:value-of select="atom:title"/>
              </a>
            </h2>
            <time><xsl:value-of select="substring(atom:updated, 1, 10)"/></time>
            <div class="content"><xsl:value-of select="atom:content" disable-output-escaping="yes"/></div>
          </article>
        </xsl:for-each>

        <footer>
          Generated from <a href="https://ledatic.org/">ledatic.org</a> CHANGELOG.
          Last updated <xsl:value-of select="substring(atom:updated, 1, 10)"/>.
        </footer>
      </body>
    </html>
  </xsl:template>
</xsl:stylesheet>
