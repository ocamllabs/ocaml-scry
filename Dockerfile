FROM ocaml/opam:alpine
COPY . /home/opam/src
RUN sudo chown -R opam /home/opam/src
RUN opam pin add -n scry /home/opam/src
RUN opam depext -uy scry
RUN opam install -vyj 2 scry
ENTRYPOINT ["opam","config","exec","--","scry"]
