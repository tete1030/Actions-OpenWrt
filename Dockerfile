FROM alpine AS first-stage
RUN touch firstfile

FROM first-stage AS second-stage
RUN echo "Hello"

FROM second-stage AS third-stage-1
RUN false

FROM second-stage AS third-stage-2
RUN true

FROM second-stage AS third-stage-3
RUN echo "[$(date)] Test" >> firstfile
