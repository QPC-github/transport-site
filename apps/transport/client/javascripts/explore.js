import { Socket } from 'phoenix'
import Leaflet from 'leaflet'
import { LeafletLayer } from 'deck.gl-leaflet'
import { ScatterplotLayer, GeoJsonLayer } from '@deck.gl/layers'

import { MapView } from '@deck.gl/core'

const socket = new Socket('/socket', { params: { token: window.userToken } })
socket.connect()
const channel = socket.channel('explore', {})
channel.join()
    .receive('ok', resp => { console.log('Joined successfully', resp) })
    .receive('error', resp => { console.log('Unable to join', resp) })

const Mapbox = {
    url: 'https://api.mapbox.com/styles/v1/istopopoki/ckg98kpoc010h19qusi9kxcct/tiles/256/{z}/{x}/{y}?access_token={accessToken}',
    accessToken: 'pk.eyJ1IjoiaXN0b3BvcG9raSIsImEiOiJjaW12eWw2ZHMwMGFxdzVtMWZ5NHcwOHJ4In0.VvZvyvK0UaxbFiAtak7aVw',
    attribution: 'Map data &copy; <a href="http://openstreetmap.org">OpenStreetMap</a> contributors <a href="https://spdx.org/licenses/ODbL-1.0.html">ODbL</a>, Imagery © <a href="http://mapbox.com">Mapbox</a>',
    maxZoom: 20
}

const metropolitanFranceBounds = [[51.1, -4.9], [41.2, 9.8]]
const map = Leaflet.map('map', { renderer: Leaflet.canvas() }).fitBounds(metropolitanFranceBounds)

Leaflet.tileLayer(Mapbox.url, {
    accessToken: Mapbox.accessToken,
    attribution: Mapbox.attribution,
    maxZoom: Mapbox.maxZoom
}).addTo(map)

const visibility = { gtfsrt: true }

function prepareLayer (layerId, layerData) {
    return new ScatterplotLayer({
        id: layerId,
        data: layerData,
        pickable: true,
        opacity: 1,
        stroked: false,
        filled: true,
        radiusMinPixels: 4,
        radiusMaxPixels: 10,
        lineWidthMinPixels: 1,
        visible: visibility.gtfsrt,
        getPosition: d => {
            return [d.position.longitude, d.position.latitude]
        },
        getRadius: d => 1000,
        getFillColor: d => [0, 150, 136, 150],
        getLineColor: d => [0, 150, 136]
    })
}

const deckGLLayer = new LeafletLayer({
    views: [
        new MapView({
            repeat: true
        })
    ],
    layers: [],
    getTooltip
})
map.addLayer(deckGLLayer)

function getTooltip ({ object, layer }) {
    if (object) {
        if (layer.id === 'bnlc-layer') {
            return { html: `<strong>Aire de covoiturage</strong><br>${object.properties.nom_lieu}` }
        } else if (layer.id === 'parkings_relais-layer') {
            return { html: `<strong>Parking relai</strong><br>${object.properties.nom}<br>Capacité : ${object.properties.nb_pr} places` }
        } else {
            return { html: `<strong>Position temps-réel</strong><br>transport_resource: ${object.transport.resource_id}<br>id: ${object.vehicle.id}` }
        }
    }
}
// internal dictionary were all layers are stored
const layers = { gtfsrt: {}, bnlc: undefined, parkings_relais: undefined }

function getLayers (layers) {
    const layersArray = Object.values(layers.gtfsrt)
    layersArray.push(layers.bnlc)
    layersArray.push(layers.parkings_relais)
    return layersArray
}

channel.on('vehicle-positions', payload => {
    if (payload.error) {
        console.log(`Resource ${payload.resource_id} failed to load`)
    } else {
        layers.gtfsrt[payload.resource_id] = prepareLayer(payload.resource_id, payload.vehicle_positions)
        deckGLLayer.setProps({ layers: getLayers(layers) })
    }
})

// handle GTFS-RT toggle
const gtfsrtCheckbox = document.getElementById('gtfs-rt-check')
gtfsrtCheckbox.addEventListener('change', (event) => {
    if (event.currentTarget.checked) {
        visibility.gtfsrt = true
    } else {
        visibility.gtfsrt = false
        for (const key in layers.gtfsrt) {
            layers.gtfsrt[key] = prepareLayer(key, [])
        }
        deckGLLayer.setProps({ layers: getLayers(layers) })
    }
})

// Handle BNLC toggle
document.getElementById('bnlc-check').addEventListener('change', (event) => {
    if (event.currentTarget.checked) {
        fetch('/api/geo-query?data=bnlc')
            .then(data => updateBNLCLayer(data.json()))
    } else {
        updateBNLCLayer(null)
    }
})

// Handle Parkings Relais toggle
document.getElementById('parkings_relais-check').addEventListener('change', (event) => {
    if (event.currentTarget.checked) {
        fetch('/api/geo-query?data=parkings-relais')
            .then(data => updateParkingsRelaisLayer(data.json()))
    } else {
        updateParkingsRelaisLayer(null)
    }
})

function updateBNLCLayer (geojson) {
    layers.bnlc = createPointsLayer(geojson, 'bnlc-layer')
    deckGLLayer.setProps({ layers: getLayers(layers) })
}
function updateParkingsRelaisLayer (geojson) {
    layers.parkings_relais = createPointsLayer(geojson, 'parkings_relais-layer')
    deckGLLayer.setProps({ layers: getLayers(layers) })
}

function createPointsLayer (geojson, id) {
    const fillColor = {
        'bnlc-layer': [255, 174, 0, 100],
        'parkings_relais-layer': [0, 33, 70, 100]
    }[id]

    return new GeoJsonLayer({
        id,
        data: geojson,
        pickable: true,
        stroked: false,
        filled: true,
        extruded: true,
        pointType: 'circle',
        getFillColor: fillColor,
        getPointRadius: 1000,
        pointRadiusUnits: 'meters',
        pointRadiusMinPixels: 2,
        pointRadiusMaxPixels: 10,
        visible: geojson !== null
    })
}

export default socket
