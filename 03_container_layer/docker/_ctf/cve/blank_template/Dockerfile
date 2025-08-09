#
# ISSUE 85 
#

FROM tomcat:9.0.8-jre8-slim

#
# INSERT readonly=false < conf/web.xml
#
RUN set -ex \
    && sed -i '/<load-on-startup>1<\/load-on-startup>/i \
    <init-param>\n\
    <param-name>readonly</param-name>\n\
    <param-value>false</param-value>\n\
    </init-param>' /usr/local/tomcat/conf/web.xml 

#
# ADD PersistentManager < conf/context.xml
#
RUN sed -i '/<\/Context>/i \
    <Manager className="org.apache.catalina.session.PersistentManager">\n\
    <Store className="org.apache.catalina.session.FileStore"/>\n\
    </Manager>' /usr/local/tomcat/conf/context.xml
#
# DEBUGS / CHECKS
#
# RUN /usr/local/tomcat/bin/version.sh
# RUN echo "-----------------------"  
# RUN grep Persistent -B1 -C2 /usr/local/tomcat/conf/context.xml 
# RUN echo "-----------------------"  
# RUN grep readonly -B3 -C4 /usr/local/tomcat/conf/web.xml 
#
#
#
# OPTIONS - to enable manager 
# COPY ./tomcat-users.xml /usr/local/tomcat/conf/tomcat-users.xml
# COPY ./context.xml /usr/local/tomcat/webapps.dist/manager/META-INF/context.xml
# COPY ./context.xml /usr/local/tomcat/webapps.dist/host-manager/META-INF/context.xml

EXPOSE 8080
