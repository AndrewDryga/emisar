ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE}
RUN pip install --no-cache-dir graphql-core==3.2.6
ADD https://raw.githubusercontent.com/braintree/graphql-api/4c8d397849df33128d5bace6555b2516c129b28e/schema.graphql /fixture/schema.graphql
RUN echo 'da1382deaeaa51a5ce565126db792e6d267ad7f69297002d1fa016a0f5caa7ef  /fixture/schema.graphql' | sha256sum -c -
